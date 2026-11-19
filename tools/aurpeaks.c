// aurpeaks: one pass over a 16-bit PCM WAV, writing waveform overview data.
//
//   aurpeaks <in.wav> <out.peaks> [bin_frames]
//
// Output: "AURPK1\0\0", then u32 bin_frames, u32 sample_rate, u32 channels,
// u32 n_bins, u64 n_frames; then n_bins records of 4 bytes:
//   i8 min, i8 max   (over all channels, scaled from 16-bit)
//   u8 rms           (of the channel mean, 0..255 = 0..full scale)
//   u8 bright        (first-difference energy / energy, 0..255)
// stdout: key=value lines (frames, rate, channels, bins, bext origin date/time)
//
// Build: gcc -O2 -o aurpeaks aurpeaks.c -lm

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const unsigned char *p) { return p[0] | p[1] << 8; }

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: aurpeaks in.wav out.peaks [bin_frames]\n");
        return 2;
    }
    uint32_t bin = argc > 3 ? (uint32_t)atoi(argv[3]) : 960;
    FILE *in = fopen(argv[1], "rb");
    if (!in) { perror("open"); return 1; }
    unsigned char h[12];
    if (fread(h, 1, 12, in) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) {
        fprintf(stderr, "not a RIFF/WAVE file\n");
        return 1;
    }
    uint16_t fmt = 0, ch = 0, bits = 0;
    uint32_t rate = 0;
    uint64_t data_bytes = 0;
    int have_data = 0;
    while (!have_data) {
        unsigned char c[8];
        if (fread(c, 1, 8, in) != 8) { fprintf(stderr, "no data chunk\n"); return 1; }
        uint32_t len = rd32(c + 4);
        if (!memcmp(c, "fmt ", 4)) {
            unsigned char f[40] = {0};
            uint32_t n = len < sizeof f ? len : sizeof f;
            if (fread(f, 1, n, in) != n) return 1;
            fseek(in, len - n + (len & 1), SEEK_CUR);
            fmt = rd16(f); ch = rd16(f + 2); rate = rd32(f + 4); bits = rd16(f + 14);
            if (fmt == 0xFFFE && n >= 26) fmt = rd16(f + 24); // WAVE_FORMAT_EXTENSIBLE
        } else if (!memcmp(c, "bext", 4)) {
            unsigned char b[602] = {0};
            uint32_t n = len < sizeof b ? len : sizeof b;
            if (fread(b, 1, n, in) != n) return 1;
            fseek(in, len - n + (len & 1), SEEK_CUR);
            if (n >= 338) printf("bext_date=%.10s\nbext_time=%.8s\n", b + 320, b + 330);
        } else if (!memcmp(c, "data", 4)) {
            // sox writes 0xffffffff placeholder only when streaming; trust len otherwise
            data_bytes = len;
            have_data = 1;
        } else {
            fseek(in, len + (len & 1), SEEK_CUR);
        }
    }
    if (fmt != 1 || bits != 16 || ch < 1) {
        fprintf(stderr, "need 16-bit PCM (fmt=%u bits=%u ch=%u)\n", fmt, bits, ch);
        return 1;
    }
    uint64_t frames = data_bytes / (2 * ch);
    uint32_t nbins = (uint32_t)((frames + bin - 1) / bin);

    FILE *out = fopen(argv[2], "wb");
    if (!out) { perror("out"); return 1; }
    fwrite("AURPK1\0\0", 1, 8, out);
    uint32_t hdr[4] = {bin, rate, ch, nbins};
    fwrite(hdr, 4, 4, out);
    fwrite(&frames, 8, 1, out);

    size_t blk = (size_t)bin * ch;
    int16_t *buf = malloc(blk * 2);
    unsigned char rec[4];
    float prev = 0;
    for (uint32_t b = 0; b < nbins; b++) {
        size_t got = fread(buf, 2 * ch, bin, in);
        int mn = 0, mx = 0;
        double e = 0, d = 0;
        for (size_t i = 0; i < got; i++) {
            int s = 0;
            for (int c = 0; c < ch; c++) {
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
        double rms = got ? sqrt(e / got) : 0;
        double br = e > 1e-12 ? d / (4 * e) : 0; // 0..1 (white noise ~0.5)
        rec[0] = (unsigned char)(int8_t)(mn >> 8);
        rec[1] = (unsigned char)(int8_t)(mx >> 8);
        rec[2] = (unsigned char)fmin(255, rms * 255 * 1.414);
        rec[3] = (unsigned char)fmin(255, sqrt(br) * 255);
        fwrite(rec, 1, 4, out);
    }
    fclose(out);
    printf("frames=%llu\nrate=%u\nchannels=%u\nbins=%u\nbin_frames=%u\n",
           (unsigned long long)frames, rate, ch, nbins, bin);
    return 0;
}
