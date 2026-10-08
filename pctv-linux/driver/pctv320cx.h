/* SPDX-License-Identifier: GPL-2.0 */
/*
 * pctv320cx - Pinnacle PCTV 320cx ExpressCard analog capture driver.
 *
 * Shared contract between the C V4L2 glue (v4l2-glue.c) and the Rust driver
 * core (pctv320cx.rs).  The Rust core owns the hardware (DiB0700 firmware
 * download, I2C tunnel, CX25843 decoder, bulk-IN streaming); the C glue owns
 * the V4L2 face, because struct video_device / struct vb2_queue are embedded
 * structs with C function-pointer tables that the Rust V4L2 abstractions do
 * not (yet) provide.
 *
 * Keeping this header free of Rust-specific markup lets it be fed to bindgen
 * to produce the Rust side of the contract.
 */
#ifndef _PCTV320CX_H_
#define _PCTV320CX_H_

#include <linux/firmware.h>
#include <linux/types.h>
#include <linux/usb.h>
#include <linux/videodev2.h>

struct vb2_buffer;
struct pctv_glue;

/* Number of inputs the glue exposes (composite / S-Video only). */
#define PCTV_INPUT_MAX			4

/*
 * TV standard selector passed to the driver core.  The core only needs to
 * know which line/colour system to program the decoder for; the v4l2_std_id
 * translation stays in the C glue.
 */
#define PCTV_STD_PAL			0
#define PCTV_STD_NTSC			1

/*
 * A capture buffer must be able to hold the largest frame we can ever
 * produce: 720 active pixels x 576 active lines x UYVY.  The size is fixed
 * (independent of the selected TV standard) so that VIDIOC_S_FMT never has
 * to resize an already allocated queue.
 */
#define PCTV_FRAME_MAX			(720 * 576 * 2)

/* Buffers the glue is willing to keep queued for the USB completion. */
#define PCTV_HANDOFF_MAX		32		/* VB2_MAX_FRAME */

/**
 * struct pctv_fmt - the negotiated capture format, in a form both sides speak.
 *
 * @width:		active pixels per line (720 for both standards)
 * @height:		active lines per frame (576 PAL, 486 NTSC)
 * @bytesperline:	bytes of active payload per line (width * 2)
 * @sizeimage:		@bytesperline * @height
 * @field:		V4L2_FIELD_*
 * @colorspace:		V4L2_COLORSPACE_*
 */
struct pctv_fmt {
	u32 width;
	u32 height;
	u32 bytesperline;
	u32 sizeimage;
	u32 field;
	u32 colorspace;
};

/**
 * struct pctv_glue_info - static description of the device, filled in at
 * creation time by the core.
 *
 * @card:		cap->card string
 * @bus_info:		cap->bus_info string
 * @input_names:	per-input names, first @num_inputs entries used
 * @num_inputs:		number of inputs (<= PCTV_INPUT_MAX)
 * @stds:		bitmask of the TV standards the device supports
 * @caps:		V4L2_CAP_* describing the device (cap->device_caps)
 */
struct pctv_glue_info {
	const char *card;
	const char *bus_info;
	const char *input_names[PCTV_INPUT_MAX];
	u32 num_inputs;
	u64 stds;
	u32 caps;
};

/**
 * struct pctv_ops - callbacks from the V4L2 glue into the driver core.
 *
 * All callbacks are called with the video device lock held, i.e. they are
 * serialised against each other, with the exception of @start_streaming and
 * @stop_streaming which additionally see the vb2 queue lock.
 *
 * @priv:		driver core cookie passed back to every callback
 * @get_fmt:		report the current format
 * @validate_fmt:	clamp a requested format without touching hardware
 * @apply_fmt:		clamp a requested format and program the decoder
 * @get_input:		report the current input index
 * @set_input:		switch the input mux
 * @get_std:		report the current TV standard selector
 * @set_std:		switch the TV standard selector (reprograms the decoder)
 * @set_ctrl:		apply a V4L2 control (V4L2_CID_*)
 * @get_signal:		report carrier presence (1 = signal locked)
 * @start_streaming:	arm the bridge and submit the capture URBs
 * @stop_streaming:	unarm the bridge and reap the capture URBs
 */
struct pctv_ops {
	void *drvdata;
	int (*get_fmt)(void *priv, struct pctv_fmt *fmt);
	int (*validate_fmt)(void *priv, struct pctv_fmt *fmt);
	int (*apply_fmt)(void *priv, const struct pctv_fmt *fmt);
	int (*get_input)(void *priv, u32 *index);
	int (*set_input)(void *priv, u32 index);
	int (*get_std)(void *priv, u32 *std);
	int (*set_std)(void *priv, u32 std);
	int (*set_ctrl)(void *priv, u32 id, s32 value);
	int (*get_signal)(void *priv, u32 *signal);
	int (*start_streaming)(void *priv);
	void (*stop_streaming)(void *priv);
};

struct pctv_glue *pctv_glue_create(struct usb_interface *intf,
				   const struct pctv_glue_info *info,
				   const struct pctv_ops *ops);
int pctv_glue_register(struct pctv_glue *glue);
void pctv_glue_unregister(struct pctv_glue *glue);
void pctv_glue_destroy(struct pctv_glue *glue);

/*
 * Frame buffer handoff.  vb2 hands buffers to the core through the C glue
 * (process context); the USB completion (softirq context) picks them up and
 * returns them.  These helpers take the necessary locking and may be called
 * from any context.
 */
/*
 * Shims for USB/device helpers that are static inline functions or macros in
 * the kernel headers, and therefore invisible to bindgen: the Rust core calls
 * these instead.
 */
int pctv_usb_register(void);
void pctv_usb_unregister(void);

void pctv_dev_set_drvdata(struct device *dev, void *data);
void *pctv_dev_get_drvdata(struct device *dev);

unsigned int pctv_usb_rcvbulkpipe(struct usb_device *dev, u8 endpoint);
unsigned int pctv_usb_sndbulkpipe(struct usb_device *dev, u8 endpoint);
void pctv_usb_fill_bulk_urb(struct urb *urb, struct usb_device *dev,
			    unsigned int pipe, void *buffer, int length,
			    usb_complete_t complete, void *context);
u8 pctv_usb_endpoint_num(const struct usb_endpoint_descriptor *ep);
bool pctv_usb_endpoint_is_in(const struct usb_endpoint_descriptor *ep);
u32 pctv_usb_endpoint_maxpkt(const struct usb_endpoint_descriptor *ep);
void *pctv_kmalloc(size_t size);
void pctv_kfree(void *p);
/* vmalloc is invisible to bindgen (linux/vmalloc.h is not included above). */
void *pctv_vmalloc(size_t size);
void pctv_vfree(const void *p);
/* Mark an URB's transfer buffer as already DMA-mapped (usb_alloc_coherent). */
void pctv_urb_use_coherent(struct urb *urb, dma_addr_t dma);

/* gfp_t values, so the Rust side does not need the kernel's gfp macros. */
unsigned int pctv_gfp_kernel(void);
unsigned int pctv_gfp_atomic(void);

const struct firmware *pctv_request_fw(struct device *dev, const char *name);
void pctv_release_fw(struct device *dev, const struct firmware *fw);

struct usb_device *pctv_interface_to_usbdev(struct usb_interface *intf);
void pctv_dev_notice(struct device *dev, const char *msg);
void pctv_dev_warn(struct device *dev, const char *msg);

void *pctv_glue_buffer_addr(struct vb2_buffer *vb);
u32 pctv_glue_buffer_size(struct vb2_buffer *vb);
struct vb2_buffer *pctv_glue_next_buffer(struct pctv_glue *glue);
void pctv_glue_buffer_done(struct pctv_glue *glue, struct vb2_buffer *vb,
			   u32 length);

/*
 * Give a buffer currently owned by the driver back to videobuf2 in QUEUED
 * state.  Used when streaming stops while the deframer is halfway through a
 * buffer, so the buffer is not left ACTIVE (videobuf2 warns and the buffer
 * leaks otherwise).
 */
void pctv_glue_buffer_requeue(struct pctv_glue *glue, struct vb2_buffer *vb);

/*
 * Streaming control, called from the Rust core.  @atomic is true when the
 * caller runs in atomic context (the URB completion handler re-arming the
 * queue).
 */
int pctv_glue_start(struct pctv_glue *glue, bool atomic);
void pctv_glue_stop(struct pctv_glue *glue);
int pctv_glue_resume_stream(struct pctv_glue *glue, bool atomic);

#endif /* _PCTV320CX_H_ */
