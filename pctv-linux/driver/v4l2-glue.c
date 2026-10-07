// SPDX-License-Identifier: GPL-2.0
/*
 * pctv320cx - V4L2 (C) glue for the Pinnacle PCTV 320cx analog capture driver.
 *
 * The driver core lives in pctv320cx.rs.  This file only implements the V4L2
 * face: the video device node, the ioctl surface, the control handler and the
 * videobuf2 queue.  It is C because the V4L2 core is driven through embedded
 * C structs (struct video_device, struct vb2_queue) and C function-pointer
 * tables which the Rust abstractions do not cover yet.
 *
 * Everything hardware related is delegated to the core through struct
 * pctv_ops; everything buffer related is delegated back through the
 * pctv_glue_buffer_*() helpers so that the core never has to touch vb2
 * internals from a URB completion.
 */

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/usb.h>

#include <media/v4l2-ctrls.h>
#include <media/v4l2-dev.h>
#include <media/v4l2-device.h>
#include <media/v4l2-event.h>
#include <media/v4l2-ioctl.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-vmalloc.h>

#include "pctv320cx.h"

struct pctv_glue {
	struct v4l2_device		v4l2_dev;
	struct v4l2_ctrl_handler	ctrl_hdl;
	struct video_device		*vdev;
	struct vb2_queue		queue;
	struct mutex			lock;

	struct pctv_glue_info		info;
	struct pctv_ops			ops;

	/*
	 * Buffers handed over by vb2 (process context) waiting to be filled by
	 * the bulk-IN completion (softirq context).
	 */
	spinlock_t			handoff_lock;
	struct vb2_buffer		*handoff[PCTV_HANDOFF_MAX];
	unsigned int			handoff_count;
	unsigned int			sequence;
};

/* ---------------------------------------------------------------- controls */

struct pctv_ctrl_desc {
	u32 id;
	const char *name;
	s32 min, max, step, def;
};

/*
 * Ranges and register mapping follow the in-tree CX25840/25843 driver
 * (drivers/media/i2c/cx25840), so the numbers userspace sees are the same as
 * on a CX23885/CX2341x based board.
 */
static const struct pctv_ctrl_desc pctv_ctrl_defs[] = {
	{ V4L2_CID_BRIGHTNESS,	"Brightness",	   0, 255, 1, 128 },
	{ V4L2_CID_CONTRAST,	"Contrast",	   0, 127, 1,  64 },
	{ V4L2_CID_SATURATION,	"Saturation",	   0, 127, 1,  64 },
	{ V4L2_CID_HUE,		"Hue",		-128, 127, 1,   0 },
};

static int pctv_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct pctv_glue *glue =
		container_of(ctrl->handler, struct pctv_glue, ctrl_hdl);

	if (!glue->ops.set_ctrl)
		return 0;

	return glue->ops.set_ctrl(glue->ops.drvdata, ctrl->id, ctrl->val);
}

static const struct v4l2_ctrl_ops pctv_ctrl_ops = {
	.s_ctrl = pctv_s_ctrl,
};

/* ------------------------------------------------------------------ format */

static void pctv_fmt_from_pix(struct pctv_fmt *dst, const struct v4l2_pix_format *src)
{
	dst->width = src->width;
	dst->height = src->height;
	dst->bytesperline = src->bytesperline;
	dst->sizeimage = src->sizeimage;
	dst->field = src->field;
	dst->colorspace = src->colorspace;
}

static void pctv_pix_from_fmt(struct v4l2_pix_format *dst, const struct pctv_fmt *src)
{
	dst->width = src->width;
	dst->height = src->height;
	dst->bytesperline = src->bytesperline;
	dst->sizeimage = src->sizeimage;
	dst->field = src->field;
	dst->colorspace = src->colorspace;
	dst->pixelformat = V4L2_PIX_FMT_YUYV;
	dst->priv = 0;
}

static int pctv_querycap(struct file *file, void *priv,
			 struct v4l2_capability *cap)
{
	struct pctv_glue *glue = video_drvdata(file);

	strscpy(cap->driver, KBUILD_MODNAME, sizeof(cap->driver));
	strscpy(cap->card, glue->info.card, sizeof(cap->card));
	strscpy(cap->bus_info, glue->info.bus_info, sizeof(cap->bus_info));
	cap->device_caps = glue->info.caps;
	cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
	return 0;
}

static int pctv_enum_fmt(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	if (f->index > 0)
		return -EINVAL;

	f->pixelformat = V4L2_PIX_FMT_YUYV;
	return 0;
}

static int pctv_g_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct pctv_glue *glue = video_drvdata(file);
	struct pctv_fmt fmt;
	int ret;

	ret = glue->ops.get_fmt(glue->ops.drvdata, &fmt);
	if (ret)
		return ret;

	pctv_pix_from_fmt(&f->fmt.pix, &fmt);
	return 0;
}

static int pctv_try_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct pctv_glue *glue = video_drvdata(file);
	struct pctv_fmt fmt;
	int ret;

	pctv_fmt_from_pix(&fmt, &f->fmt.pix);
	ret = glue->ops.validate_fmt(glue->ops.drvdata, &fmt);
	if (ret)
		return ret;

	pctv_pix_from_fmt(&f->fmt.pix, &fmt);
	return 0;
}

static int pctv_s_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct pctv_glue *glue = video_drvdata(file);
	struct pctv_fmt fmt;
	int ret;

	if (vb2_is_busy(&glue->queue))
		return -EBUSY;

	pctv_fmt_from_pix(&fmt, &f->fmt.pix);
	ret = glue->ops.apply_fmt(glue->ops.drvdata, &fmt);
	if (ret)
		return ret;

	ret = glue->ops.get_fmt(glue->ops.drvdata, &fmt);
	if (ret)
		return ret;

	pctv_pix_from_fmt(&f->fmt.pix, &fmt);
	return 0;
}

/* ------------------------------------------------------------------ inputs */

static int pctv_enum_input(struct file *file, void *priv, struct v4l2_input *i)
{
	struct pctv_glue *glue = video_drvdata(file);

	if (i->index >= glue->info.num_inputs)
		return -EINVAL;

	strscpy(i->name, glue->info.input_names[i->index], sizeof(i->name));
	i->type = V4L2_INPUT_TYPE_CAMERA;
	i->std = glue->info.stds;
	return 0;
}

static int pctv_g_input(struct file *file, void *priv, unsigned int *i)
{
	struct pctv_glue *glue = video_drvdata(file);
	u32 index = 0;
	int ret = glue->ops.get_input(glue->ops.drvdata, &index);

	*i = index;
	return ret;
}

static int pctv_s_input(struct file *file, void *priv, unsigned int i)
{
	struct pctv_glue *glue = video_drvdata(file);

	if (i >= glue->info.num_inputs)
		return -EINVAL;

	return glue->ops.set_input(glue->ops.drvdata, i);
}

/* -------------------------------------------------------------- TV standard */

/*
 * VIDIOC_ENUMSTD is served by the V4L2 core from vidioc_g_std, so only the
 * g/s pair needs an implementation here.
 */
static int pctv_g_std(struct file *file, void *priv, v4l2_std_id *std)
{
	struct pctv_glue *glue = video_drvdata(file);
	u32 sel = PCTV_STD_PAL;
	int ret = glue->ops.get_std(glue->ops.drvdata, &sel);

	*std = sel == PCTV_STD_NTSC ? V4L2_STD_NTSC_M : V4L2_STD_PAL_B;
	return ret;
}

static int pctv_s_std(struct file *file, void *priv, v4l2_std_id std)
{
	struct pctv_glue *glue = video_drvdata(file);

	if (!(glue->info.stds & std))
		return -EINVAL;

	return glue->ops.set_std(glue->ops.drvdata,
				 (std & V4L2_STD_525_60) ? PCTV_STD_NTSC
								: PCTV_STD_PAL);
}

/*
 * There is no RF tuner in this driver: the CX25843 is fed directly from the
 * composite/S-Video inputs.  VIDIOC_G_TUNER still reports the decoder name
 * and, importantly, the carrier lock state, which is how userspace (mplayer,
 * tvtime, ...) checks whether anything is plugged in.
 */
static int pctv_g_tuner(struct file *file, void *priv, struct v4l2_tuner *t)
{
	struct pctv_glue *glue = video_drvdata(file);
	u32 signal = 0;

	if (t->index > 0)
		return -EINVAL;

	strscpy(t->name, "CX25843", sizeof(t->name));
	t->type = V4L2_TUNER_ANALOG_TV;
	t->capability = V4L2_TUNER_CAP_NORM;
	t->rangelow = 0;
	t->rangehigh = 0;
	t->rxsubchans = V4L2_TUNER_SUB_MONO;
	t->audmode = V4L2_TUNER_MODE_MONO;

	if (glue->ops.get_signal)
		glue->ops.get_signal(glue->ops.drvdata, &signal);
	t->signal = signal ? 0xffff : 0;
	return 0;
}

static int pctv_g_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
	struct pctv_glue *glue = video_drvdata(file);
	u32 sel = PCTV_STD_PAL;

	if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	memset(&a->parm, 0, sizeof(a->parm));
	a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
	a->parm.capture.timeperframe.numerator = 1;
	a->parm.capture.timeperframe.denominator = 25;

	if (!glue->ops.get_std(glue->ops.drvdata, &sel) && sel == PCTV_STD_NTSC) {
		a->parm.capture.timeperframe.numerator = 1001;
		a->parm.capture.timeperframe.denominator = 30000;
	}
	return 0;
}

static int pctv_s_parm(struct file *file, void *priv, struct v4l2_streamparm *a)
{
	if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	return pctv_g_parm(file, priv, a);
}

/* --------------------------------------------------------------- videobuf2 */

static int pctv_queue_setup(struct vb2_queue *q, unsigned int *num_buffers,
			    unsigned int *num_planes, unsigned int sizes[],
			    struct device *alloc_devs[])
{
	if (*num_planes)
		return sizes[0] < PCTV_FRAME_MAX ? -EINVAL : 0;

	*num_planes = 1;
	sizes[0] = PCTV_FRAME_MAX;
	return 0;
}

static int pctv_start_streaming(struct vb2_queue *q, unsigned int count)
{
	struct pctv_glue *glue = q->drv_priv;

	if (!glue->ops.start_streaming)
		return 0;

	return glue->ops.start_streaming(glue->ops.drvdata);
}

static void pctv_stop_streaming(struct vb2_queue *q)
{
	struct pctv_glue *glue = q->drv_priv;
	unsigned long flags;
	unsigned int i;

	if (glue->ops.stop_streaming)
		glue->ops.stop_streaming(glue->ops.drvdata);

	/* Give back anything the core did not manage to return. */
	spin_lock_irqsave(&glue->handoff_lock, flags);
	for (i = 0; i < glue->handoff_count; i++)
		vb2_buffer_done(glue->handoff[i], VB2_BUF_STATE_QUEUED);
	glue->handoff_count = 0;
	spin_unlock_irqrestore(&glue->handoff_lock, flags);
}

static void pctv_buf_queue(struct vb2_buffer *vb)
{
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
	struct vb2_queue *q = vb->vb2_queue;
	struct pctv_glue *glue = q->drv_priv;
	unsigned long flags;

	vbuf->field = V4L2_FIELD_INTERLACED;

	spin_lock_irqsave(&glue->handoff_lock, flags);
	if (glue->handoff_count < ARRAY_SIZE(glue->handoff))
		glue->handoff[glue->handoff_count++] = vb;
	else
		vb2_buffer_done(vb, VB2_BUF_STATE_QUEUED);
	spin_unlock_irqrestore(&glue->handoff_lock, flags);
}

static const struct vb2_ops pctv_vb2_ops = {
	.queue_setup = pctv_queue_setup,
	.start_streaming = pctv_start_streaming,
	.stop_streaming = pctv_stop_streaming,
	.buf_queue = pctv_buf_queue,
};

/* -------------------------------------------------------- buffer handoff API */

void *pctv_glue_buffer_addr(struct vb2_buffer *vb)
{
	return vb2_plane_vaddr(vb, 0);
}

u32 pctv_glue_buffer_size(struct vb2_buffer *vb)
{
	return vb2_plane_size(vb, 0);
}

struct vb2_buffer *pctv_glue_next_buffer(struct pctv_glue *glue)
{
	struct vb2_buffer *vb = NULL;
	unsigned long flags;

	spin_lock_irqsave(&glue->handoff_lock, flags);
	if (glue->handoff_count) {
		glue->handoff_count--;
		vb = glue->handoff[glue->handoff_count];
		glue->handoff[glue->handoff_count] = NULL;
	}
	spin_unlock_irqrestore(&glue->handoff_lock, flags);
	return vb;
}

void pctv_glue_buffer_done(struct pctv_glue *glue, struct vb2_buffer *vb,
			   u32 length)
{
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);

	if (length > vb2_plane_size(vb, 0))
		length = vb2_plane_size(vb, 0);

	vb2_set_plane_payload(vb, 0, length);
	vbuf->sequence = glue->sequence++;
	/* The state is chosen here, not passed from the Rust core: the core must
	 * not have to mirror enum vb2_buffer_state (a stale copy of
	 * VB2_BUF_STATE_DONE is exactly what broke the first streaming run).
	 */
	vb2_buffer_done(vb, VB2_BUF_STATE_DONE);
}

void pctv_glue_buffer_requeue(struct pctv_glue *glue, struct vb2_buffer *vb)
{
	if (!vb)
		return;
	vb2_buffer_done(vb, VB2_BUF_STATE_QUEUED);
}

/* ------------------------------------------------------------- ioctl table */

static const struct v4l2_ioctl_ops pctv_ioctl_ops = {
	.vidioc_querycap = pctv_querycap,
	.vidioc_enum_fmt_vid_cap = pctv_enum_fmt,
	.vidioc_g_fmt_vid_cap = pctv_g_fmt,
	.vidioc_try_fmt_vid_cap = pctv_try_fmt,
	.vidioc_s_fmt_vid_cap = pctv_s_fmt,

	.vidioc_reqbufs = vb2_ioctl_reqbufs,
	.vidioc_create_bufs = vb2_ioctl_create_bufs,
	.vidioc_prepare_buf = vb2_ioctl_prepare_buf,
	.vidioc_querybuf = vb2_ioctl_querybuf,
	.vidioc_qbuf = vb2_ioctl_qbuf,
	.vidioc_dqbuf = vb2_ioctl_dqbuf,
	.vidioc_expbuf = vb2_ioctl_expbuf,
	.vidioc_streamon = vb2_ioctl_streamon,
	.vidioc_streamoff = vb2_ioctl_streamoff,

	.vidioc_enum_input = pctv_enum_input,
	.vidioc_g_input = pctv_g_input,
	.vidioc_s_input = pctv_s_input,

	.vidioc_g_std = pctv_g_std,
	.vidioc_s_std = pctv_s_std,

	.vidioc_g_tuner = pctv_g_tuner,

	.vidioc_g_parm = pctv_g_parm,
	.vidioc_s_parm = pctv_s_parm,

	.vidioc_subscribe_event = v4l2_ctrl_subscribe_event,
	.vidioc_unsubscribe_event = v4l2_event_unsubscribe,
};

static const struct v4l2_file_operations pctv_fops = {
	.owner = THIS_MODULE,
	.open = v4l2_fh_open,
	.release = vb2_fop_release,
	.read = vb2_fop_read,
	.poll = vb2_fop_poll,
	.unlocked_ioctl = video_ioctl2,
	.mmap = vb2_fop_mmap,
};

/* ------------------------------------------------------------ create/register */

struct pctv_glue *pctv_glue_create(struct usb_interface *intf,
				   const struct pctv_glue_info *info,
				   const struct pctv_ops *ops)
{
	struct pctv_glue *glue;
	unsigned int i;
	int ret;

	glue = kzalloc(sizeof(*glue), GFP_KERNEL);
	if (!glue)
		return NULL;

	glue->info = *info;
	glue->ops = *ops;
	if (glue->info.num_inputs > PCTV_INPUT_MAX)
		glue->info.num_inputs = PCTV_INPUT_MAX;

	mutex_init(&glue->lock);
	spin_lock_init(&glue->handoff_lock);

	ret = v4l2_device_register(&intf->dev, &glue->v4l2_dev);
	if (ret) {
		kfree(glue);
		return NULL;
	}
	strscpy(glue->v4l2_dev.name, glue->info.card,
		sizeof(glue->v4l2_dev.name));

	v4l2_ctrl_handler_init(&glue->ctrl_hdl, ARRAY_SIZE(pctv_ctrl_defs));
	for (i = 0; i < ARRAY_SIZE(pctv_ctrl_defs); i++)
		v4l2_ctrl_new_std(&glue->ctrl_hdl, &pctv_ctrl_ops,
				  pctv_ctrl_defs[i].id, pctv_ctrl_defs[i].min,
				  pctv_ctrl_defs[i].max, pctv_ctrl_defs[i].step,
				  pctv_ctrl_defs[i].def);
	if (glue->ctrl_hdl.error) {
		ret = glue->ctrl_hdl.error;
		goto err_ctrl;
	}

	glue->vdev = video_device_alloc();
	if (!glue->vdev) {
		ret = -ENOMEM;
		goto err_ctrl;
	}
	glue->vdev->release = video_device_release_empty;
	glue->vdev->fops = &pctv_fops;
	glue->vdev->ioctl_ops = &pctv_ioctl_ops;
	glue->vdev->lock = &glue->lock;
	glue->vdev->queue = &glue->queue;
	glue->vdev->ctrl_handler = &glue->ctrl_hdl;
	glue->vdev->v4l2_dev = &glue->v4l2_dev;
	glue->vdev->device_caps = glue->info.caps;
	video_set_drvdata(glue->vdev, glue);

	glue->queue = (struct vb2_queue) {
		.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		.io_modes = VB2_MMAP | VB2_USERPTR | VB2_READ,
		.mem_ops = &vb2_vmalloc_memops,
		.ops = &pctv_vb2_ops,
		.drv_priv = glue,
		.lock = &glue->lock,
		.min_queued_buffers = 2,
		.gfp_flags = GFP_KERNEL,
		/* Without an explicit timestamp type vb2_queue_init() warns and
		 * leaves the buffer timestamps as TIMESTAMP_UNKNOWN.
		 */
		.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC,
	};

	ret = vb2_queue_init(&glue->queue);
	if (ret)
		goto err_vdev;

	return glue;

err_vdev:
	video_device_release(glue->vdev);
err_ctrl:
	v4l2_ctrl_handler_free(&glue->ctrl_hdl);
	v4l2_device_unregister(&glue->v4l2_dev);
	kfree(glue);
	return NULL;
}

int pctv_glue_register(struct pctv_glue *glue)
{
	int ret;

	/* Push the control defaults into the decoder.  Not fatal: if the
	 * decoder did not come up (missing v4l-cx25840.fw, say) the node still
	 * appears and the failure is visible through VIDIOC_G_INPUT_STATUS and
	 * dmesg rather than the card disappearing entirely.
	 */
	if (v4l2_ctrl_handler_setup(&glue->ctrl_hdl))
		dev_warn(glue->v4l2_dev.dev,
			 "control defaults could not be pushed to the decoder\n");

	ret = video_register_device(glue->vdev, VFL_TYPE_VIDEO, -1);
	if (ret)
		return ret;

	video_set_drvdata(glue->vdev, glue);
	return 0;
}

void pctv_glue_unregister(struct pctv_glue *glue)
{
	vb2_video_unregister_device(glue->vdev);
}

void pctv_glue_destroy(struct pctv_glue *glue)
{
	vb2_queue_release(&glue->queue);
	video_device_release(glue->vdev);
	v4l2_ctrl_handler_free(&glue->ctrl_hdl);
	v4l2_device_unregister(&glue->v4l2_dev);
	kfree(glue);
}

/* ------------------------------------------------------------ streaming control
 *
 * Called from the Rust core: vb2_streamon() is what runs the queue, and it
 * in turn calls ->start_streaming(), which dispatches to ops->start_streaming.
 */
int pctv_glue_start(struct pctv_glue *glue, bool atomic)
{
	/* This kernel's vb2_streamon() takes no gfp mask; @atomic is kept for
	 * the driver's own bookkeeping.
	 */
	(void)atomic;
	return vb2_streamon(&glue->queue, V4L2_BUF_TYPE_VIDEO_CAPTURE);
}

void pctv_glue_stop(struct pctv_glue *glue)
{
	vb2_streamoff(&glue->queue, V4L2_BUF_TYPE_VIDEO_CAPTURE);
}

int pctv_glue_resume_stream(struct pctv_glue *glue, bool atomic)
{
	(void)atomic;
	return vb2_streamon(&glue->queue, V4L2_BUF_TYPE_VIDEO_CAPTURE);
}

/* The module metadata (description, license, firmware, parameters) comes
 * from the module!() macro in pctv320cx.rs; this file only contributes the
 * device table, which MODULE_DEVICE_TABLE in usb-shim.c emits. */
