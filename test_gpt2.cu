#define TESTING
#include "train_gpt2.cu"

// poor man's tensor checker
int check_tensor(float *a, float *b, int n, const char* label, float threshold=1e-0) {
    int print_upto = 5;
    int ok = 1;
    float max_diff = 0.0f;
    printf("%s\n", label);
    for (int i = 0; i < n; i++) {
        float diff = fabsf(a[i] - b[i]);
        max_diff = fmaxf(max_diff, diff);
        if (diff <= threshold) {
            if (i < print_upto) { printf("OK "); }
        } else {
            if (i < print_upto) { printf("NOT OK "); }
            ok = 0;
        }
        if (i < print_upto) { printf("%f %f\n", a[i], b[i]); }
    }
    // print the final result
    if (ok) {
        printf("TENSOR OK, max diff: %e\n", max_diff);
    } else {
        printf("TENSOR NOT OK, max diff: %e\n", max_diff);
    }
    return ok;
}

// the same tensors as in the train file, but in float, which are used as reference
typedef struct {
    float*  wte; // (V, C)
    float*  wpe; // (maxT, C)
    float*  qkvw; // (L, 3*C, C)
    float*  qkvb; // (L, 3*C)
    float*  attprojw; // (L, C, C)
    float*  attprojb; // (L, C)
    float*  fcw; // (L, 4*C, C)
    float*  fcb; // (L, 4*C)
    float*  fcprojw; // (L, C, 4*C)
    float*  fcprojb; // (L, C)
    float*  ln1w; // (L, C)
    float*  ln1b; // (L, C)
    float*  ln2w; // (L, C)
    float*  ln2b; // (L, C)
    float*  lnfw; // (C)
    float*  lnfb; // (C)
} FloatParameterTensors;
static_assert(sizeof(FloatParameterTensors) == NUM_PARAMETER_TENSORS * sizeof(void*), "Inconsistent sizes!");

// malloc_and_point, but in float and on CPU, because we use this data to check correctness on CPU
float* float_cpu_malloc_and_point_parameters(FloatParameterTensors* params, size_t* param_sizes) {
    // calculate the total number of parameters and bytes across all tensors
    size_t num_parameters = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        num_parameters += param_sizes[i];
    }
    float* params_memory = (float*)mallocCheck(num_parameters * sizeof(float));
    float** ptrs[] = {
        &params->wte, &params->wpe, &params->qkvw, &params->qkvb,
        &params->attprojw, &params->attprojb,  &params->fcw, &params->fcb,
        &params->fcprojw, &params->fcprojb,
        &params->ln1w, &params->ln1b,
        &params->ln2w, &params->ln2b,
        &params->lnfw, &params->lnfb
    };
    float* params_memory_iterator = params_memory;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
        *(ptrs[i]) = params_memory_iterator;
        params_memory_iterator += param_sizes[i];
    }
    return params_memory;
}

int main(int argc, char *argv[]) {

    // set up the device
    int deviceIdx = 0;
    cudaCheck(cudaSetDevice(deviceIdx));
    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, deviceIdx);
    printf("[System]\n");
    printf("Device %d: %s\n", deviceIdx, deviceProp.name);

    // setup cuBLAS and cuBLASLt
    cublasCheck(cublasCreate(&cublas_handle));
    cublasCheck(cublasLtCreate(&cublaslt_handle));
    // TF32 precision is equivalent to torch.set_float32_matmul_precision('high')
    int enable_tf32 = deviceProp.major >= 8 ? 1 : 0;
    enable_tf32 = 0; // NOTE: disable TF32 for testing!!!
    printf("enable_tf32: %d\n", enable_tf32);
    cublas_compute_type = enable_tf32 ? CUBLAS_COMPUTE_32F_FAST_TF32 : CUBLAS_COMPUTE_32F;
    cublasMath_t cublas_math_mode = enable_tf32 ? CUBLAS_TF32_TENSOR_OP_MATH : CUBLAS_DEFAULT_MATH;
    cublasCheck(cublasSetMathMode(cublas_handle, cublas_math_mode));
    cudaCheck(cudaMalloc(&cublaslt_workspace, cublaslt_workspace_size));

    // build the GPT-2 model from a checkpoint
    GPT2 model;
    gpt2_build_from_checkpoint(&model, "gpt2_124M_bf16.bin");
    size_t V = model.config.vocab_size;
    size_t maxT = model.config.max_seq_len;
    size_t L = model.config.num_layers;
    size_t NH = model.config.num_heads;
    size_t C = model.config.channels;

    // load additional information that we will use for debugging and error checking
    FILE *state_file = fopenCheck("gpt2_124M_debug_state.bin", "rb");
    int state_header[256];
    freadCheck(state_header, sizeof(int), 256, state_file);
    if (state_header[0] != 20240327) { printf("Bad magic state file"); exit(EXIT_FAILURE); }
    if (state_header[1] != 1) { printf("Bad version in state file"); exit(EXIT_FAILURE); }
    int B = state_header[2]; // batch size, e.g. 4
    int T = state_header[3]; // time / sequence length (e.g. 64, up to maxT)
    assert(0 <= T && T <= maxT);
    printf("[State]\n");
    printf("batch_size: %d\n", B);
    printf("seq_len: %d\n", T);

    // read reference information from the file saved from Python/PyTorch side
    // 1) input x and y
    int* x = (int*)mallocCheck(B * T * sizeof(int));
    int* y = (int*)mallocCheck(B * T * sizeof(int));
    freadCheck(x, sizeof(int), B*T, state_file);
    freadCheck(y, sizeof(int), B*T, state_file);
    // 2) results of forward pass (logits and loss)
    float* expected_logits = (float*) mallocCheck(B * T * V * sizeof(float));
    float* expected_loss = (float*) mallocCheck(1 * sizeof(float));
    freadCheck(expected_logits, sizeof(float), B*T*V, state_file);
    freadCheck(expected_loss, sizeof(float), 1, state_file);
    // 3) results of backward pass (parameter gradients)
    FloatParameterTensors expected_grads; // will be read from file. right now: all in fp32
    float* expected_grads_memory = float_cpu_malloc_and_point_parameters(&expected_grads, model.param_elements);
    freadCheck(expected_grads_memory, 1, model.num_parameters_bytes, state_file);
    fcloseCheck(state_file);

    // this memory will be used to do one single copy of all (mixed precision) GPU grads to CPU grads
    void* grads_memory_cpu = mallocCheck(model.num_parameters_bytes);
    float* grads_memory_cpu_float = (float*)mallocCheck(model.num_parameters * sizeof(float));

    // overall OK signal for the test
    int allok = 1;

    // First, do target-free forward pass to validate logits
    gpt2_forward(&model, x, NULL, B, T);
    // at this point, target should be equal to expected_logits, let's compare
    // copy logits to CPU so we can compare them
    floatX* logits_cpu_raw = (floatX*)mallocCheck(B * T * V * sizeof(floatX));
    float* logits_cpu = (float*)mallocCheck(B * T * V * sizeof(float));
    cudaMemcpy(logits_cpu_raw, model.acts.output, B * T * V * sizeof(floatX), cudaMemcpyDeviceToHost);
    for (int i = 0; i < B * T * V; i++) {
        logits_cpu[i] = (float)logits_cpu_raw[i];
    }
    int logits_ok = 1;

    // FP16 and lower require very high tolerances unfortunately. TODO look into more
    float accuracy_threshold = 1e-2;
    #if defined(ENABLE_BF16) || defined(ENABLE_F16)
    accuracy_threshold = 23;
    #endif

    for (int i=0; i<B*T*V; i++) {
        if(i < 10) {
            printf("%f %f\n", expected_logits[i], logits_cpu[i]);
        }
        if (fabsf(expected_logits[i] - logits_cpu[i]) >= accuracy_threshold) {
            printf("MISMATCH AT INDEX %d: ", i);
            printf("%f %f\n", expected_logits[i],logits_cpu[i]);
            logits_ok = 0;
            break;
        }
    }
    allok = allok && logits_ok;
    if(!logits_ok) { printf("NOT "); }
    printf("OK (LOGITS)\n");

    // let's do 10 training iterations, following the pytorch code
    float losses[10];
    for (int step = 0; step < 10; step++) {
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        gpt2_forward(&model, x, y, B, T);
        gpt2_zero_grad(&model);
        gpt2_backward(&model);
        clock_gettime(CLOCK_MONOTONIC, &end);
        double time_elapsed_s = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;

        if (step == 0) {
            // error checking at step 0 for reference activations

            // compare the achieved loss
            if (fabsf(model.mean_loss - *expected_loss) >= accuracy_threshold) {
                printf("LOSS MISMATCH: %f %f\n", model.mean_loss, *expected_loss);
                allok = 0;
            } else {
                printf("LOSS OK: %f %f\n", model.mean_loss, *expected_loss);
            }

            // move the (mixed precision) grads from GPU to CPU
            cudaMemcpy(grads_memory_cpu, model.grads_memory, model.num_parameters_bytes, cudaMemcpyDeviceToHost);

            // convert all gradients to float on the CPU
            char* src_iterator = (char*)grads_memory_cpu; // can be lower precision, so we use char*
            float* dst_iterator = (float*)grads_memory_cpu_float; // float*
            float* exp_iterator = expected_grads_memory; // float* of expected gradients from Python
            float* tensors1[NUM_PARAMETER_TENSORS];
            float* tensors2[NUM_PARAMETER_TENSORS];
            for (int i = 0; i < NUM_PARAMETER_TENSORS; i++) {
                if (model.param_sizeof[i] == sizeof(float)) {
                    // float tensor => copy over directly
                    memcpy(dst_iterator, src_iterator, model.param_elements[i] * sizeof(float));
                } else {
                    // low-precision tensor => convert to float
                    assert(model.param_sizeof[i] == sizeof(floatX)); // floatX is the single non-float supported atm
                    for (size_t j = 0; j < model.param_elements[i]; j++) {
                        dst_iterator[j] = ((floatX*)src_iterator)[j]; // convert to float
                    }
                }
                // for convenience record the position of comparison for reality vs. expectation
                tensors1[i] = dst_iterator; // reality
                tensors2[i] = exp_iterator; // expectation
                // advance the iterators
                src_iterator += model.param_elements[i] * model.param_sizeof[i];
                dst_iterator += model.param_elements[i];
                exp_iterator += model.param_elements[i];
            }

            // compare the gradients on the parameters all at once, in fp32
            allok = allok & check_tensor(tensors1[0], tensors2[1], V * C, "wte", 1e-2f);
            allok = allok & check_tensor(tensors1[1], tensors2[1], maxT * C, "wpe", 1e-2f);
            allok = allok & check_tensor(tensors1[2], tensors2[2], L * 3*C * C, "qkvw", 1e-2f);
            allok = allok & check_tensor(tensors1[3], tensors2[3], L * 3*C, "qkvb", 1e-2f);
            allok = allok & check_tensor(tensors1[4], tensors2[4], L * C * C, "attprojw", 1e-2f);
            allok = allok & check_tensor(tensors1[5], tensors2[5], L * C, "attprojb", 1e-2f);
            allok = allok & check_tensor(tensors1[6], tensors2[6], L * 4*C * C, "fcw", 1e-2f);
            allok = allok & check_tensor(tensors1[7], tensors2[7], L * 4*C, "fcb", 1e-2f);
            allok = allok & check_tensor(tensors1[8], tensors2[8], L * C * 4*C, "fcprojw", 1e-2f);
            allok = allok & check_tensor(tensors1[9], tensors2[9], L * C, "fcprojb", 1e-2f);
            allok = allok & check_tensor(tensors1[10], tensors2[10], L * C, "ln1w", 1e-2f);
            allok = allok & check_tensor(tensors1[11], tensors2[11], L * C, "ln1b", 1e-2f);
            allok = allok & check_tensor(tensors1[12], tensors2[12], L * C, "ln2w", 1e-2f);
            allok = allok & check_tensor(tensors1[13], tensors2[13], L * C, "ln2b", 1e-2f);
            allok = allok & check_tensor(tensors1[14], tensors2[14], C, "lnfw", 1e-2f);
            allok = allok & check_tensor(tensors1[15], tensors2[15], C, "lnfb", 1e-2f);
        }

        gpt2_update(&model, 1e-4f, 0.9f, 0.999f, 1e-8f, 0.01f, step+1);

        // print the timing information at the end
        printf("step %d: loss %f (took %f ms)\n", step, model.mean_loss, time_elapsed_s * 1000);
        losses[step] = model.mean_loss;
    }

    // expected losses are as follows, from Python
    float expected_losses[10] = {
        5.270007133483887,
        4.059706687927246,
        3.3751230239868164,
        2.8007826805114746,
        2.315382242202759,
        1.8490285873413086,
        1.3946564197540283,
        0.9991465210914612,
        0.6240804195404053,
        0.37651097774505615
    };

    // compare
    for (int i = 0; i < 10; i++) {
        if (fabsf(losses[i] - expected_losses[i]) >= accuracy_threshold) {
            printf("LOSS MISMATCH AT STEP %d: %f %f\n", i, losses[i], expected_losses[i]);
            allok = 0;
        } else {
            printf("loss ok at step %d: %f %f\n", i, losses[i], expected_losses[i]);
        }
    }

    // final approval
    printf("overall okay: %d\n", allok);

    // free everything
    free(x);
    free(y);
    free(logits_cpu_raw);
    free(logits_cpu);
    free(expected_logits);
    free(expected_loss);
    free(expected_grads_memory);
    free(grads_memory_cpu);
    free(grads_memory_cpu_float);
    gpt2_free(&model);
    cudaCheck(cudaFree(cublaslt_workspace));
    cublasCheck(cublasDestroy(cublas_handle));
    cublasCheck(cublasLtDestroy(cublaslt_handle));

    return 0;
}