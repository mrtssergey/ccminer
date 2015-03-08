/*
 * whirlpool routine (djm)
 * whirlpoolx routine (provos alexis)
 */
extern "C"
{
#include "sph/sph_whirlpool.h"
#include "miner.h"
}

#include "cuda_helper.h"

static uint32_t *d_hash[MAX_GPUS];

extern void whirlpoolx_cpu_init(int thr_id, int threads);
extern void whirlpoolx_setBlock_80(void *pdata, const void *ptarget);
extern uint32_t cpu_whirlpoolx(int thr_id, uint32_t threads, uint32_t startNounce);
extern void whirlpoolx_precompute();

// CPU Hash function
extern "C" void whirlxHash(void *state, const void *input)
{

	sph_whirlpool_context ctx_whirlpool;

	unsigned char hash[64];
	unsigned char hash_xored[32];

	memset(hash, 0, sizeof hash);

	sph_whirlpool_init(&ctx_whirlpool);
	sph_whirlpool(&ctx_whirlpool, input, 80);
	sph_whirlpool_close(&ctx_whirlpool, hash);

    
	for (uint32_t i = 0; i < 32; i++){
	        hash_xored[i] = hash[i] ^ hash[i + 16];
	}
	memcpy(state, hash_xored, 32);
}

static bool init[MAX_GPUS] = { 0 };

int scanhash_whirlpoolx(int thr_id, uint32_t *pdata, uint32_t *ptarget, uint32_t max_nonce, uint32_t *hashes_done)
{
	const uint32_t first_nonce = pdata[19];
	uint32_t endiandata[20];

	uint32_t throughput = device_intensity(thr_id, __func__, 1 << 26); // 256*4096
	throughput = min(throughput, max_nonce - first_nonce);

	if (opt_benchmark)
		ptarget[7] = 0x0f;

	if (!init[thr_id]) {

		cudaSetDevice(device_map[thr_id]);
		cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
		cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);

		// Konstanten kopieren, Speicher belegen
		CUDA_CALL_OR_RET_X(cudaMalloc(&d_hash[thr_id], 16 * sizeof(uint32_t) * throughput),0);
		whirlpoolx_cpu_init(thr_id, throughput);

		init[thr_id] = true;
	}

	for (int k=0; k < 20; k++) {
		be32enc(&endiandata[k], ((uint32_t*)pdata)[k]);
	}

	whirlpoolx_setBlock_80((void*)endiandata, &ptarget[6]);
	whirlpoolx_precompute();
	uint32_t n=pdata[19];
	uint32_t foundNonce;
	do {
		if(n+throughput>=max_nonce){
//			applog(LOG_INFO, "GPU #%d: Preventing glitch.", thr_id);
			throughput=max_nonce-n;
		}
		foundNonce = cpu_whirlpoolx(thr_id, throughput, n);
		if (foundNonce != 0xffffffff)
		{
			const uint32_t Htarg = ptarget[7];
			uint32_t vhash64[8];
			be32enc(&endiandata[19], foundNonce);
			whirlxHash(vhash64, endiandata);

			if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget)) {
				int res = 1;
//				uint32_t secNonce = cuda_check_hash_suppl(thr_id, throughput, pdata[19], d_hash[thr_id], 1);
				*hashes_done = n - first_nonce + throughput;
/*				if (secNonce != 0) {
					pdata[21] = secNonce;
					res++;
				}*/
				if (opt_benchmark) applog(LOG_INFO, "found nounce", thr_id, foundNonce, vhash64[7], Htarg);

				pdata[19] = foundNonce;
				return res;
			}
			else if (vhash64[7] > Htarg) {
				applog(LOG_INFO, "GPU #%d: result for %08x is not in range: %x > %x", thr_id, foundNonce, vhash64[7], Htarg);
			}
			else {
				applog(LOG_INFO, "GPU #%d: result for %08x does not validate on CPU!", thr_id, foundNonce);
			}
		}
		n += throughput;

	} while (n < max_nonce && !work_restart[thr_id].restart);
	*hashes_done = n - first_nonce;
	return 0;
}
