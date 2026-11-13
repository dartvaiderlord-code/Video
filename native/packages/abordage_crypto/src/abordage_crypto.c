#include "monocypher.h"
#if defined(_WIN32)
#define ABR_EXPORT __declspec(dllexport)
#else
#define ABR_EXPORT __attribute__((visibility("default")))
#endif
ABR_EXPORT void abr_lock(uint8_t *cipher, uint8_t *tag, const uint8_t *key,
    const uint8_t *nonce, const uint8_t *aad, size_t aad_size,
    const uint8_t *plain, size_t size) {
  crypto_aead_lock(cipher, tag, key, nonce, aad, aad_size, plain, size);
}
ABR_EXPORT int abr_unlock(uint8_t *plain, const uint8_t *tag, const uint8_t *key,
    const uint8_t *nonce, const uint8_t *aad, size_t aad_size,
    const uint8_t *cipher, size_t size) {
  return crypto_aead_unlock(plain, tag, key, nonce, aad, aad_size, cipher, size);
}
