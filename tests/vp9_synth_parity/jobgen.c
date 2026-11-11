// Synthetic NVDEC VP9 jobs from an IVF file, for tests/vp9_synth_parity_test.sh.
//   jobgen <in.ivf> <out dir>
// Decodes the stream with stock libvpx 1.17.0 plus jobgen_hook.patch (two NULL-by-default hooks in vp9_decode_frame)
// and, for every decoded frame (hidden alt-refs included; show-existing frames carry no job), writes what a game's
// driver hands NVDEC as an S2V9 v1 record (the S2A_NVDEC_VP9_CAPTURE layout that tests/vp9_native_parity reads):
//   PictureInfo (256 B), NVDEC EntropyProbs (3744 B, this frame's probabilities after its compressed-header updates,
//   before backward adaptation), Last/Golden/Alt/output surface offsets, the tile data, and a trailer whose
//   Y/U/V FNV-1a-64 hashes are libvpx's own decode of that frame (MV / count hashes left 0).
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vpx/vp8dx.h"
#include "vpx/vpx_decoder.h"
#include "vp9/common/vp9_entropymode.h"
#include "vp9/common/vp9_onyxc_int.h"
#include "vp9/decoder/vp9_decoder.h"

extern void (*s2a_jobgen_header)(VP9Decoder *pbi, const uint8_t *tiles, const uint8_t *tiles_end);
extern void (*s2a_jobgen_done)(VP9Decoder *pbi);

// Ryujinx.Graphics.Nvdec.Types.Vp9.EntropyProbs (same layout as android/codecs/vpxbench/hdr.c)
typedef struct {
    uint8_t kf_y_e0_7[10][10][8], kf_y_e8[10][10], pad384[3], seg_tree[7], seg_pred[3], pad391[15];
    uint8_t kf_uv_e0_7[10][8], kf_uv_e8[10], pad3fa[6], inter_mode[7][4], intra_inter[4], uv_e0_7[10][8];
    uint8_t tx8[2][1], tx16[2][2], tx32[2][3], y_e8[4], y_e0_7[4][8], kf_part[16][4], part[16][4], uv_e8[10];
    uint8_t sw_interp[4][2], comp_inter[5], skip[4], joints[3], sign[2], class0[2][1], fp[2][3], class0_hp[2], hp[2];
    uint8_t classes[2][10], class0_fp[2][2][3], bits[2][10], single_ref[5][2], comp_ref[5], pad58f[17];
    uint8_t coef[4][2][2][6][6][4];
} nvdec_probs;
static_assert(sizeof(nvdec_probs) == 3744, "NVDEC EntropyProbs");

enum { PIC = 256, REG = 32, TRAILER = 41 };
enum { F_KEY = 1, F_LAST_KEY = 2, F_SIZE_CHANGED = 4, F_ERROR_RES = 8, F_LAST_SHOW = 16, F_INTRA_ONLY = 32 };

static const char *out_dir;
static long job;
static uint8_t *rec;   // record being built between the two hooks
static size_t rec_len;

static void w16(uint8_t *p, unsigned v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void w32(uint8_t *p, uint32_t v) { w16(p, v & 0xffff); w16(p + 2, v >> 16); }
static void w64(uint8_t *p, uint64_t v) { w32(p, (uint32_t)v); w32(p + 4, (uint32_t)(v >> 32)); }

static uint64_t fnv_plane(const uint8_t *p, int stride, int w, int h)
{
    uint64_t x = 0xcbf29ce484222325ULL;
    for (int y = 0; y < h; y++)
        for (int i = 0; i < w; i++) x = (x ^ p[(long)y * stride + i]) * 0x100000001b3ULL;
    return x;
}

static void die(const char *why)
{
    fprintf(stderr, "jobgen: job %ld: %s\n", job, why);
    exit(1);
}

static void fill_probs(const VP9_COMMON *cm, nvdec_probs *g)
{
    const FRAME_CONTEXT *fc = cm->fc;
    memset(g, 0, sizeof *g);
    for (int i = 0; i < 10; i++)
        for (int j = 0; j < 10; j++)
        {
            memcpy(g->kf_y_e0_7[i][j], vp9_kf_y_mode_prob[i][j], 8);
            g->kf_y_e8[i][j] = vp9_kf_y_mode_prob[i][j][8];
        }
    memcpy(g->seg_tree, cm->seg.tree_probs, 7);
    memcpy(g->seg_pred, cm->seg.pred_probs, 3);
    for (int i = 0; i < 10; i++)
    {
        memcpy(g->kf_uv_e0_7[i], vp9_kf_uv_mode_prob[i], 8);
        g->kf_uv_e8[i] = vp9_kf_uv_mode_prob[i][8];
        memcpy(g->uv_e0_7[i], fc->uv_mode_prob[i], 8);
        g->uv_e8[i] = fc->uv_mode_prob[i][8];
    }
    for (int i = 0; i < 7; i++) memcpy(g->inter_mode[i], fc->inter_mode_probs[i], 3);
    memcpy(g->intra_inter, fc->intra_inter_prob, 4);
    memcpy(g->tx8, fc->tx_probs.p8x8, sizeof g->tx8);
    memcpy(g->tx16, fc->tx_probs.p16x16, sizeof g->tx16);
    memcpy(g->tx32, fc->tx_probs.p32x32, sizeof g->tx32);
    for (int i = 0; i < 4; i++)
    {
        memcpy(g->y_e0_7[i], fc->y_mode_prob[i], 8);
        g->y_e8[i] = fc->y_mode_prob[i][8];
    }
    for (int i = 0; i < 16; i++)
    {
        memcpy(g->kf_part[i], vp9_kf_partition_probs[i], 3);
        memcpy(g->part[i], fc->partition_prob[i], 3);
    }
    memcpy(g->sw_interp, fc->switchable_interp_prob, sizeof g->sw_interp);
    memcpy(g->comp_inter, fc->comp_inter_prob, 5);
    memcpy(g->skip, fc->skip_probs, 3);
    memcpy(g->joints, fc->nmvc.joints, 3);
    for (int i = 0; i < 2; i++)
    {
        const nmv_component *c = &fc->nmvc.comps[i];
        g->sign[i] = c->sign;
        memcpy(g->classes[i], c->classes, 10);
        g->class0[i][0] = c->class0[0];
        memcpy(g->bits[i], c->bits, 10);
        memcpy(g->class0_fp[i], c->class0_fp, sizeof g->class0_fp[i]);
        memcpy(g->fp[i], c->fp, 3);
        g->class0_hp[i] = c->class0_hp;
        g->hp[i] = c->hp;
    }
    memcpy(g->single_ref, fc->single_ref_prob, sizeof g->single_ref);
    memcpy(g->comp_ref, fc->comp_ref_prob, 5);
    for (int a = 0; a < 4; a++)
        for (int b = 0; b < 2; b++)
            for (int c = 0; c < 2; c++)
                for (int d = 0; d < 6; d++)
                    for (int e = 0; e < 6; e++) memcpy(g->coef[a][b][c][d][e], fc->coef_probs[a][b][c][d][e], 3);
}

// Surface offsets the driver would program: one per libvpx frame buffer.
static uint32_t luma_of(int fb) { return (uint32_t)(fb + 1) << 24; }

static void on_header(VP9Decoder *pbi, const uint8_t *tiles, const uint8_t *tiles_end)
{
    static const uint8_t filter_to_literal[] = { 1, 0, 2, 3 };   // EIGHTTAP, SMOOTH, SHARP, BILINEAR → bitstream literal
    const VP9_COMMON *cm = &pbi->common;
    const int key = cm->frame_type == KEY_FRAME, intra = frame_is_intra_only(cm);
    const size_t n_tile = (size_t)(tiles_end - tiles);

    if (rec != NULL) die("header hook twice without a finished frame");
    if (cm->bit_depth != VPX_BITS_8 || cm->subsampling_x != 1 || cm->subsampling_y != 1) die("not 8-bit 4:2:0");
    rec_len = 32 + PIC + sizeof(nvdec_probs) + REG + n_tile + TRAILER;
    rec = calloc(1, rec_len);
    if (rec == NULL) die("out of memory");
    memcpy(rec, "S2V9", 4);
    w32(rec + 4, 1);
    w32(rec + 12, PIC);
    w32(rec + 16, sizeof(nvdec_probs));
    w32(rec + 20, REG);
    w32(rec + 24, (uint32_t)n_tile);

    uint8_t *pic = rec + 32, *reg = pic + PIC + sizeof(nvdec_probs);
    int fb[4], w[4], h[4];
    fb[3] = cm->new_fb_idx;
    w[3] = cm->width;
    h[3] = cm->height;
    for (int i = 0; i < 3; i++)
    {
        const RefBuffer *r = &cm->frame_refs[i];
        // A key / intra-only frame reads no reference; the driver still programs some surface, here the output.
        fb[i] = intra ? fb[3] : r->idx;
        w[i] = intra ? w[3] : r->buf->y_crop_width;
        h[i] = intra ? h[3] : r->buf->y_crop_height;
    }
    for (int i = 0; i < 4; i++)
    {
        w16(pic + 72 + 8 * i, (unsigned)w[i]);
        w16(pic + 74 + 8 * i, (unsigned)h[i]);
        w16(pic + 76 + 8 * i, (unsigned)((w[i] + 63) & ~63));
        w16(pic + 78 + 8 * i, (unsigned)((((w[i] + 1) >> 1) + 63) & ~63));
        w32(reg + 8 * i, luma_of(fb[i]));
        w32(reg + 8 * i + 4, luma_of(fb[i]) + 0x800000);
    }
    w32(pic + 48, (uint32_t)n_tile);
    uint32_t flags = (key ? F_KEY : 0) | (cm->last_frame_type == KEY_FRAME ? F_LAST_KEY : 0) |
                     (cm->width != cm->last_width || cm->height != cm->last_height ? F_SIZE_CHANGED : 0) |
                     (cm->error_resilient_mode ? F_ERROR_RES : 0) | (cm->last_show_frame ? F_LAST_SHOW : 0) |
                     (!key && cm->intra_only ? F_INTRA_ONLY : 0);
    w32(pic + 104, flags);
    // The parity runner (and the game driver) derive "use the previous frame's MVs" from these flags; libvpx
    // decided it from its own state (also on intra frames, where nothing reads it). If they differ on an inter frame
    // the jobs would not describe this stream.
    const int use_prev = !(flags & (F_KEY | F_ERROR_RES | F_SIZE_CHANGED | F_INTRA_ONLY | F_LAST_KEY)) && (flags & F_LAST_SHOW);
    if (!intra && use_prev != cm->use_prev_frame_mvs) die("flags do not reproduce libvpx's use_prev_frame_mvs (intra-only previous frame?)");
    // The native path hands these to the managed decoder (Vp9NativeHeader.Check), so a stream using them could not
    // show native == managed == libvpx; refuse it rather than count fallbacks.
    if (cm->seg.enabled) die("segmentation (native path falls back)");
    if (cm->y_dc_delta_q < 0 || cm->uv_dc_delta_q < 0 || cm->uv_ac_delta_q < 0) die("negative delta_q (native path falls back)");
    for (int i = 0; i < 4; i++) pic[108 + i] = (uint8_t)(int8_t)cm->ref_frame_sign_bias[i];
    pic[112] = (uint8_t)cm->lf.filter_level;
    pic[113] = (uint8_t)cm->lf.sharpness_level;
    pic[114] = (uint8_t)cm->base_qindex;
    pic[115] = (uint8_t)cm->y_dc_delta_q;
    pic[116] = (uint8_t)cm->uv_ac_delta_q;
    pic[117] = (uint8_t)cm->uv_dc_delta_q;
    pic[118] = (uint8_t)pbi->mb.lossless;
    pic[119] = (uint8_t)cm->tx_mode;
    pic[120] = (uint8_t)cm->allow_high_precision_mv;
    pic[121] = cm->interp_filter == SWITCHABLE ? 4 : filter_to_literal[cm->interp_filter];
    pic[122] = (uint8_t)cm->reference_mode;
    pic[123] = (uint8_t)(int8_t)cm->comp_fixed_ref;
    pic[124] = (uint8_t)(int8_t)cm->comp_var_ref[0];
    pic[125] = (uint8_t)(int8_t)cm->comp_var_ref[1];
    pic[126] = (uint8_t)cm->log2_tile_cols;
    pic[127] = (uint8_t)cm->log2_tile_rows;
    pic[128] = cm->seg.enabled;
    pic[129] = cm->seg.update_map;
    pic[130] = cm->seg.temporal_update;
    pic[131] = cm->seg.abs_delta;
    for (int s = 0; s < 8; s++)
    {
        w32(pic + 132 + 4 * s, cm->seg.feature_mask[s]);
        for (int f = 0; f < 4; f++) w16(pic + 164 + 8 * s + 2 * f, (uint16_t)cm->seg.feature_data[s][f]);
    }
    pic[228] = cm->lf.mode_ref_delta_enabled;
    for (int i = 0; i < 4; i++) pic[229 + i] = (uint8_t)cm->lf.ref_deltas[i];
    for (int i = 0; i < 2; i++) pic[233 + i] = (uint8_t)cm->lf.mode_deltas[i];

    nvdec_probs g;
    fill_probs(cm, &g);
    memcpy(pic + PIC, &g, sizeof g);
    memcpy(reg + REG, tiles, n_tile);
}

static void on_done(VP9Decoder *pbi)
{
    const VP9_COMMON *cm = &pbi->common;
    const YV12_BUFFER_CONFIG *b = &cm->buffer_pool->frame_bufs[cm->new_fb_idx].buf;
    if (rec == NULL) die("frame finished without a header hook");
    uint8_t *t = rec + rec_len - TRAILER;
    t[0] = 1;
    w64(t + 1, fnv_plane(b->y_buffer, b->y_stride, b->y_crop_width, b->y_crop_height));
    w64(t + 9, fnv_plane(b->u_buffer, b->uv_stride, b->uv_crop_width, b->uv_crop_height));
    w64(t + 17, fnv_plane(b->v_buffer, b->uv_stride, b->uv_crop_width, b->uv_crop_height));
    char path[4096];
    snprintf(path, sizeof path, "%s/frame_%06ld.bin", out_dir, job);
    FILE *f = fopen(path, "wb");
    if (f == NULL || fwrite(rec, 1, rec_len, f) != rec_len || fclose(f) != 0) die("cannot write the record");
    free(rec);
    rec = NULL;
    job++;
}

int main(int argc, char **argv)
{
    if (argc != 3) return fprintf(stderr, "usage: jobgen <in.ivf> <out dir>\n"), 2;
    out_dir = argv[2];
    FILE *f = fopen(argv[1], "rb");
    uint8_t hdr[32];
    if (f == NULL || fread(hdr, 1, 32, f) != 32 || memcmp(hdr, "DKIF", 4) != 0) return fprintf(stderr, "%s: not IVF\n", argv[1]), 1;
    fseek(f, hdr[6] | hdr[7] << 8, SEEK_SET);

    vpx_codec_ctx_t c;
    vpx_codec_dec_cfg_t cfg = { 1, 0, 0 };   // one thread: decode_tiles, loop filter inline
    if (vpx_codec_dec_init(&c, vpx_codec_vp9_dx(), &cfg, 0) != VPX_CODEC_OK) return fprintf(stderr, "vpx init failed\n"), 1;
    s2a_jobgen_header = on_header;
    s2a_jobgen_done = on_done;

    uint8_t fh[12], *buf = NULL;
    long packets = 0;
    while (fread(fh, 1, 12, f) == 12)
    {
        uint32_t n = fh[0] | fh[1] << 8 | fh[2] << 16 | (uint32_t)fh[3] << 24;
        buf = realloc(buf, n);
        if (buf == NULL || fread(buf, 1, n, f) != n) return fprintf(stderr, "%s: truncated\n", argv[1]), 1;
        if (vpx_codec_decode(&c, buf, n, NULL, 0) != VPX_CODEC_OK)
            return fprintf(stderr, "packet %ld: %s\n", packets, vpx_codec_error_detail(&c)), 1;
        vpx_codec_iter_t it = NULL;
        while (vpx_codec_get_frame(&c, &it) != NULL) {}
        packets++;
    }
    vpx_codec_destroy(&c);
    if (rec != NULL) die("stream ended inside a frame");
    printf("%s: %ld packets → %ld jobs\n", argv[1], packets, job);
    return job > 0 ? 0 : 1;
}
