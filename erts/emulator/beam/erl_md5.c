/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2026. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * %CopyrightEnd%
 */
#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#ifdef ERL_INTERFACE
/*
 * Built by erl_interface with no sys.h
 * Include and define the stuff we need.
 */
#  include <stdint.h>
#  include <stddef.h>
#  include <string.h>
#  define sys_memcpy memcpy
#  define sys_memzero(PTR, N) memset(PTR, 0, N)
#  define put_little_int32(i, s) do {              \
        ((uint8_t*)(s))[3] = (uint8_t)((i) >> 24); \
        ((uint8_t*)(s))[2] = (uint8_t)((i) >> 16); \
        ((uint8_t*)(s))[1] = (uint8_t)((i) >> 8);  \
        ((uint8_t*)(s))[0] = (uint8_t)(i);         \
    } while (0)

#  define get_little_int32(s)                      \
    ((((uint8_t*) (s))[3] << 24) |                 \
     (((uint8_t*) (s))[2] << 16) |                 \
     (((uint8_t*) (s))[1] << 8) |                  \
     (((uint8_t*) (s))[0]))

#  define put_little_int64(i, s) do {                        \
        ((uint8_t*)(s))[7] = (uint8_t)((uint64_t)(i) >> 56); \
        ((uint8_t*)(s))[6] = (uint8_t)((uint64_t)(i) >> 48); \
        ((uint8_t*)(s))[5] = (uint8_t)((uint64_t)(i) >> 40); \
        ((uint8_t*)(s))[4] = (uint8_t)((uint64_t)(i) >> 32); \
        ((uint8_t*)(s))[3] = (uint8_t)((uint64_t)(i) >> 24); \
        ((uint8_t*)(s))[2] = (uint8_t)((uint64_t)(i) >> 16); \
        ((uint8_t*)(s))[1] = (uint8_t)((uint64_t)(i) >> 8);  \
        ((uint8_t*)(s))[0] = (uint8_t)((uint64_t)(i));       \
    } while (0)

#  include "eidef.h"
#else
#  include "sys.h"
#endif

#include "erl_md5.h"

#define A0 0x67452301
#define B0 0xefcdab89
#define C0 0x98badcfe
#define D0 0x10325476

static size_t pad(const uint8_t* last_part, size_t size, uint8_t pad_buf[],
                  size_t tot_size);
static void hash_part(const uint8_t* msg_part, erts_md5_state*);

void erts_md5_init(erts_md5_state* state)
{
    state->a = A0;
    state->b = B0;
    state->c = C0;
    state->d = D0;
    state->len = 0;
    state->tot_len = 0;
    sys_memzero(state->buf, sizeof(state->buf));
}

void erts_md5_update(erts_md5_state* state, const uint8_t* msg, size_t msg_len)
{
    const uint8_t* part = msg;
    size_t left = msg_len;

    if (state->len > 0) {
        uint8_t* buf = state->buf;
        size_t copy_size;
        buf += state->len;
        copy_size = 64-state->len;
        if (copy_size < left) {
            sys_memcpy(buf, part, copy_size);
            part += copy_size;
            left -= copy_size;
            hash_part(state->buf, state);
            state->len = 0;
            state->tot_len += 64;
        } else {
            sys_memcpy(buf, part, left);
            state->len += left;
            return;
        }
    }

    while (left >= 64) {
        hash_part(part, state);
        left -= 64;
        part += 64;
        state->tot_len += 64;
    }

    if (left > 0) {
        ASSERT(left < 64);
        sys_memcpy(state->buf, part, left);
        state->len = left;
    }
}

void erts_md5_finish(uint8_t* out, erts_md5_state* state)
{
    uint8_t pad_buf[2*64];
    const uint8_t* part = state->buf;
    size_t left = state->len;

    left = pad(part, left, pad_buf, state->tot_len+state->len);
    part = pad_buf;

    while (left > 0) {
        hash_part(part, state);
        left -= 64;
        part += 64;
    }

    put_little_int32(state->a, out);
    put_little_int32(state->b, out+4);
    put_little_int32(state->c, out+8);
    put_little_int32(state->d, out+12);
}

void erts_md5(const uint8_t* msg, size_t msg_len, uint8_t* out)
{
    erts_md5_state state;

    erts_md5_init(&state);
    erts_md5_update(&state, msg, msg_len);
    erts_md5_finish(out, &state);
}


static void hash_part(const uint8_t* msg_part, erts_md5_state *state)
{
    uint32_t a = state->a;
    uint32_t b = state->b;
    uint32_t c = state->c;
    uint32_t d = state->d;
    uint32_t x[16];
    int i;

    for (i = 0; i < 16; i++) {
        x[i] = get_little_int32(msg_part + i*4);
    }

    /* The fully unrolled transformation from RFC 1321; constant rotation
     * amounts and round constants let the compiler emit immediate rotate
     * instructions with no per-round branching, which is substantially
     * faster than the rolled loop this replaces. */
#define MD5_ROTL(v, s) (((v) << (s)) | ((v) >> (32 - (s))))
#define MD5_F(b, c, d) ((d) ^ ((b) & ((c) ^ (d))))
#define MD5_G(b, c, d) ((c) ^ ((d) & ((b) ^ (c))))
#define MD5_H(b, c, d) ((b) ^ (c) ^ (d))
#define MD5_I(b, c, d) ((c) ^ ((b) | ~(d)))
#define MD5_STEP(fun, a, b, c, d, k, s, t)                                    \
    do {                                                                      \
        (a) += fun((b), (c), (d)) + x[k] + (uint32_t)(t);                     \
        (a) = MD5_ROTL((a), (s));                                             \
        (a) += (b);                                                           \
    } while (0)

    MD5_STEP(MD5_F, a, b, c, d,  0,  7, 0xd76aa478);
    MD5_STEP(MD5_F, d, a, b, c,  1, 12, 0xe8c7b756);
    MD5_STEP(MD5_F, c, d, a, b,  2, 17, 0x242070db);
    MD5_STEP(MD5_F, b, c, d, a,  3, 22, 0xc1bdceee);
    MD5_STEP(MD5_F, a, b, c, d,  4,  7, 0xf57c0faf);
    MD5_STEP(MD5_F, d, a, b, c,  5, 12, 0x4787c62a);
    MD5_STEP(MD5_F, c, d, a, b,  6, 17, 0xa8304613);
    MD5_STEP(MD5_F, b, c, d, a,  7, 22, 0xfd469501);
    MD5_STEP(MD5_F, a, b, c, d,  8,  7, 0x698098d8);
    MD5_STEP(MD5_F, d, a, b, c,  9, 12, 0x8b44f7af);
    MD5_STEP(MD5_F, c, d, a, b, 10, 17, 0xffff5bb1);
    MD5_STEP(MD5_F, b, c, d, a, 11, 22, 0x895cd7be);
    MD5_STEP(MD5_F, a, b, c, d, 12,  7, 0x6b901122);
    MD5_STEP(MD5_F, d, a, b, c, 13, 12, 0xfd987193);
    MD5_STEP(MD5_F, c, d, a, b, 14, 17, 0xa679438e);
    MD5_STEP(MD5_F, b, c, d, a, 15, 22, 0x49b40821);

    MD5_STEP(MD5_G, a, b, c, d,  1,  5, 0xf61e2562);
    MD5_STEP(MD5_G, d, a, b, c,  6,  9, 0xc040b340);
    MD5_STEP(MD5_G, c, d, a, b, 11, 14, 0x265e5a51);
    MD5_STEP(MD5_G, b, c, d, a,  0, 20, 0xe9b6c7aa);
    MD5_STEP(MD5_G, a, b, c, d,  5,  5, 0xd62f105d);
    MD5_STEP(MD5_G, d, a, b, c, 10,  9, 0x02441453);
    MD5_STEP(MD5_G, c, d, a, b, 15, 14, 0xd8a1e681);
    MD5_STEP(MD5_G, b, c, d, a,  4, 20, 0xe7d3fbc8);
    MD5_STEP(MD5_G, a, b, c, d,  9,  5, 0x21e1cde6);
    MD5_STEP(MD5_G, d, a, b, c, 14,  9, 0xc33707d6);
    MD5_STEP(MD5_G, c, d, a, b,  3, 14, 0xf4d50d87);
    MD5_STEP(MD5_G, b, c, d, a,  8, 20, 0x455a14ed);
    MD5_STEP(MD5_G, a, b, c, d, 13,  5, 0xa9e3e905);
    MD5_STEP(MD5_G, d, a, b, c,  2,  9, 0xfcefa3f8);
    MD5_STEP(MD5_G, c, d, a, b,  7, 14, 0x676f02d9);
    MD5_STEP(MD5_G, b, c, d, a, 12, 20, 0x8d2a4c8a);

    MD5_STEP(MD5_H, a, b, c, d,  5,  4, 0xfffa3942);
    MD5_STEP(MD5_H, d, a, b, c,  8, 11, 0x8771f681);
    MD5_STEP(MD5_H, c, d, a, b, 11, 16, 0x6d9d6122);
    MD5_STEP(MD5_H, b, c, d, a, 14, 23, 0xfde5380c);
    MD5_STEP(MD5_H, a, b, c, d,  1,  4, 0xa4beea44);
    MD5_STEP(MD5_H, d, a, b, c,  4, 11, 0x4bdecfa9);
    MD5_STEP(MD5_H, c, d, a, b,  7, 16, 0xf6bb4b60);
    MD5_STEP(MD5_H, b, c, d, a, 10, 23, 0xbebfbc70);
    MD5_STEP(MD5_H, a, b, c, d, 13,  4, 0x289b7ec6);
    MD5_STEP(MD5_H, d, a, b, c,  0, 11, 0xeaa127fa);
    MD5_STEP(MD5_H, c, d, a, b,  3, 16, 0xd4ef3085);
    MD5_STEP(MD5_H, b, c, d, a,  6, 23, 0x04881d05);
    MD5_STEP(MD5_H, a, b, c, d,  9,  4, 0xd9d4d039);
    MD5_STEP(MD5_H, d, a, b, c, 12, 11, 0xe6db99e5);
    MD5_STEP(MD5_H, c, d, a, b, 15, 16, 0x1fa27cf8);
    MD5_STEP(MD5_H, b, c, d, a,  2, 23, 0xc4ac5665);

    MD5_STEP(MD5_I, a, b, c, d,  0,  6, 0xf4292244);
    MD5_STEP(MD5_I, d, a, b, c,  7, 10, 0x432aff97);
    MD5_STEP(MD5_I, c, d, a, b, 14, 15, 0xab9423a7);
    MD5_STEP(MD5_I, b, c, d, a,  5, 21, 0xfc93a039);
    MD5_STEP(MD5_I, a, b, c, d, 12,  6, 0x655b59c3);
    MD5_STEP(MD5_I, d, a, b, c,  3, 10, 0x8f0ccc92);
    MD5_STEP(MD5_I, c, d, a, b, 10, 15, 0xffeff47d);
    MD5_STEP(MD5_I, b, c, d, a,  1, 21, 0x85845dd1);
    MD5_STEP(MD5_I, a, b, c, d,  8,  6, 0x6fa87e4f);
    MD5_STEP(MD5_I, d, a, b, c, 15, 10, 0xfe2ce6e0);
    MD5_STEP(MD5_I, c, d, a, b,  6, 15, 0xa3014314);
    MD5_STEP(MD5_I, b, c, d, a, 13, 21, 0x4e0811a1);
    MD5_STEP(MD5_I, a, b, c, d,  4,  6, 0xf7537e82);
    MD5_STEP(MD5_I, d, a, b, c, 11, 10, 0xbd3af235);
    MD5_STEP(MD5_I, c, d, a, b,  2, 15, 0x2ad7d2bb);
    MD5_STEP(MD5_I, b, c, d, a,  9, 21, 0xeb86d391);

#undef MD5_STEP
#undef MD5_I
#undef MD5_H
#undef MD5_G
#undef MD5_F
#undef MD5_ROTL

    state->a += a;
    state->b += b;
    state->c += c;
    state->d += d;
}


static size_t pad(const uint8_t* last_part, size_t size, uint8_t pad_buf[],
                  size_t tot_size)
{
    size_t filled = (size + 1) % 64;
    size_t zeroes;
    const uint64_t tot_bit_size = tot_size * 8;
    uint8_t* pad_ptr = pad_buf;

    zeroes = (64 - 8 - filled) & (64 - 1);

    sys_memcpy(pad_ptr, last_part, size);
    pad_ptr += size;
    *pad_ptr++ = 128;
    sys_memzero(pad_ptr, zeroes);
    pad_ptr += zeroes;
    put_little_int64(tot_bit_size, pad_ptr);
    pad_ptr += 8;

    ASSERT((pad_ptr - pad_buf) % 64 == 0);

    return pad_ptr - pad_buf;
}
