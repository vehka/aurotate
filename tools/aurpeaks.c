// aurpeaks: waveform overview data from a stream of 16-bit PCM.
//
//   aurpeaks -r rate -c channels [-b bin_frames] [-p progress_file] out.peaks < raw_s16le
//   aurpeaks -w in.wav                      (print BWF bext origination, then exit)
//
// The input is interleaved signed 16-bit little-endian PCM on stdin (e.g. from
// `sox in -t raw -e signed -b 16 -`).
//
// Output ("AURPK2"), little-endian:
//   0  char[8]  "AURPK2\0\0"
//   8  u32      bin_frames (level 0)
//  12  u32      sample rate
//  16  u32      channels
//  20  u32      n0: level 0 bins (0 while the analysis runs: count them from
//               the file size; level 0 is written as the stream arrives)
//  24  u64      n_frames
//  32  u32      n1: level 1 bins (16 level-0 bins each)
//  36  u32      n2: level 2 bins (256 level-0 bins each)
//  40  n0 records, then n1, then n2; 4 bytes each:
//        i8 min, i8 max  (over all channels, scaled from 16-bit)
//        u8 rms          (of the channel mean, 0..255 = 0..full scale)
//        u8 bright       (sqrt of first-difference energy / 4·energy, 0..255;
//                         white noise ~180, a low hum ~0)
//   Reduced levels: min of mins, max of maxes, rms over the bins, bright
//   weighted by energy.
// stdout: key=value lines (frames, rate, channels, bins, bin_frames)
//
// Build: gcc -O2 -o aurpeaks aurpeaks.c -lm

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define R1 16
#define R2 256
#define HDR 40

static uint32_t rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

// accumulator for a reduced level
typedef struct {
    int mn, mx;
    double e2;   // sum of rms^2 (normalised)
    double be;   // sum of bright^2 * rms^2
    unsigned n;
    unsigned char *out;
    size_t len, cap;
} level_t;

static void lv_reset(level_t *l) { l->mn = 127; l->mx = -128; l->e2 = 0; l->be = 0; l->n = 0; }

static void lv_flush(level_t *l) {
    if (l->n == 0) return;
    if (l->len + 4 > l->cap) {
        l->cap = l->cap ? l->cap * 2 : 4096;
        l->out = realloc(l->out, l->cap);
        if (!l->out) { perror("realloc"); exit(1); }
    }
    double rms = sqrt(l->e2 / l->n);
    double br = l->e2 > 1e-12 ? sqrt(l->be / l->e2) : 0;
    unsigned char *r = l->out + l->len;
    r[0] = (unsigned char)(int8_t)l->mn;
    r[1] = (unsigned char)(int8_t)l->mx;
    r[2] = (unsigned char)fmin(255, rms * 255);
    r[3] = (unsigned char)fmin(255, br * 255);
    l->len += 4;
    lv_reset(l);
}

static void lv_add(level_t *l, const unsigned char *rec, unsigned per) {
    int8_t mn = (int8_t)rec[0], mx = (int8_t)rec[1];
    double rms = rec[2] / 255.0, br = rec[3] / 255.0;
    if (mn < l->mn) l->mn = mn;
    if (mx > l->mx) l->mx = mx;
    l->e2 += rms * rms;
    l->be += br * br * rms * rms;
    if (++l->n == per) lv_flush(l);
}

static int bext(const char *path) {
    FILE *in = fopen(path, "rb");
    if (!in) { perror("open"); return 1; }
    unsigned char h[12];
    if (fread(h, 1, 12, in) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) { fclose(in); return 0; }
    for (;;) {
        unsigned char c[8];
        if (fread(c, 1, 8, in) != 8) break;
        uint32_t len = rd32(c + 4);
        if (!memcmp(c, "bext", 4)) {
            unsigned char b[602] = {0};
            uint32_t n = len < sizeof b ? len : sizeof b;
            if (fread(b, 1, n, in) != n) break;
            if (n >= 338) printf("bext_date=%.10s\nbext_time=%.8s\n", b + 320, b + 330);
            break;
        }
        if (!memcmp(c, "data", 4)) break;
        if (fseek(in, len + (len & 1), SEEK_CUR)) break;
    }
    fclose(in);
    return 0;
}

static void put32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

int main(int argc, char **argv) {
    uint32_t rate = 0, ch = 0, bin = 0;
    const char *prog = NULL;
    int o;
    while ((o = getopt(argc, argv, "r:c:b:p:w:")) != -1) {
        switch (o) {
        case 'r': rate = (uint32_t)atoi(optarg); break;
        case 'c': ch = (uint32_t)atoi(optarg); break;
        case 'b': bin = (uint32_t)atoi(optarg); break;
        case 'p': prog = optarg; break;
        case 'w': return bext(optarg);
        default: goto usage;
        }
    }
    if (optind >= argc || !rate || !ch) goto usage;
    if (!bin) bin = rate / 50; // 20 ms

    FILE *out = fopen(argv[optind], "wb");
    if (!out) { perror("out"); return 1; }
    unsigned char hdr[HDR] = "AURPK2";
    put32(hdr + 8, bin); put32(hdr + 12, rate); put32(hdr + 16, ch);
    fwrite(hdr, 1, HDR, out);

    size_t blk = (size_t)bin * ch;
    int16_t *buf = malloc(blk * 2);
    level_t l1 = {0}, l2 = {0};
    lv_reset(&l1); lv_reset(&l2);
    uint64_t frames = 0;
    uint32_t n0 = 0;
    float prev = 0;
    size_t have = 0; // bytes in buf (a partial frame may arrive at a pipe boundary)
    for (;;) {
        size_t got = fread((char *)buf + have, 1, blk * 2 - have, stdin);
        have += got;
        if (have < blk * 2 && !feof(stdin) && !ferror(stdin)) continue;
        size_t nf = have / (2 * ch);
        if (nf == 0) break;
        int mn = 0, mx = 0;
        double e = 0, d = 0;
        for (size_t i = 0; i < nf; i++) {
            int s = 0;
            for (uint32_t c = 0; c < ch; c++) {
                int v = buf[i * ch + c];
                if (v < mn) mn = v;
                if (v > mx) mx = v;
                s += v;
            }
            float m = (float)s / (ch * 32768.f);
            e += m * m;
            d += (m - prev) * (m - prev);
            prev = m;
        }
        double rms = sqrt(e / nf);
        double br = e > 1e-12 ? d / (4 * e) : 0; // 0..1
        unsigned char rec[4];
        rec[0] = (unsigned char)(int8_t)(mn >> 8);
        rec[1] = (unsigned char)(int8_t)(mx >> 8);
        rec[2] = (unsigned char)fmin(255, rms * 255 * 1.414);
        rec[3] = (unsigned char)fmin(255, sqrt(br) * 255);
        fwrite(rec, 1, 4, out);
        lv_add(&l1, rec, R1);
        lv_add(&l2, rec, R2);
        frames += nf;
        n0++;
        have = 0;
        if (prog && (n0 % 2048) == 0) {
            FILE *p = fopen(prog, "w");
            if (p) { fprintf(p, "%llu\n", (unsigned long long)frames); fclose(p); }
            fflush(out);
        }
        if (nf < bin) break;
    }
    lv_flush(&l1);
    lv_flush(&l2);
    fwrite(l1.out, 1, l1.len, out);
    fwrite(l2.out, 1, l2.len, out);
    put32(hdr + 20, n0);
    for (int i = 0; i < 8; i++) hdr[24 + i] = (unsigned char)(frames >> (8 * i));
    put32(hdr + 32, (uint32_t)(l1.len / 4));
    put32(hdr + 36, (uint32_t)(l2.len / 4));
    fseek(out, 0, SEEK_SET);
    fwrite(hdr, 1, HDR, out);
    if (fclose(out)) { perror("close"); return 1; }
    printf("frames=%llu\nrate=%u\nchannels=%u\nbins=%u\nbin_frames=%u\n",
           (unsigned long long)frames, rate, ch, n0, bin);
    return 0;
usage:
    fprintf(stderr, "usage: aurpeaks -r rate -c ch [-b bin_frames] [-p progress] out.peaks < s16le\n"
                    "       aurpeaks -w in.wav\n");
    return 2;
}
