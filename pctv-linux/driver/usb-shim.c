// SPDX-License-Identifier: GPL-2.0
/*
 * pctv320cx - USB shim for the Pinnacle PCTV 320cx analog capture driver.
 *
 * The driver logic lives in pctv320cx.rs.  This file provides the two things
 * the Rust side cannot do against the current kernel Rust API:
 *
 *   - it owns the `struct usb_driver` registration: kernel::usb::Driver hands
 *     the driver an opaque & usb::Interface, and the raw struct usb_device /
 *     struct urb access needed for bulk-IN streaming is not exposed yet;
 *
 *   - it wraps the USB/platform helpers that are static inline functions or
 *     macros (dev_set_drvdata(), usb_fill_bulk_urb(), usb_rcvbulkpipe(),
 *     request_firmware(), the usb_endpoint_*() accessors), which bindgen does
 *     not emit and therefore cannot be called from Rust.
 */

#include <linux/module.h>
#include <linux/usb.h>

#include "pctv320cx.h"

/* Implemented in pctv320cx.rs. */
extern int pctv320cx_probe(struct usb_interface *intf,
			   const struct usb_device_id *id);
extern void pctv320cx_disconnect(struct usb_interface *intf);

static const struct usb_device_id pctv_usb_ids[] = {
	{ USB_DEVICE(0x2304, 0x022e) },	/* Pinnacle PCTV 320cx ExpressCard */
	{ }
};
MODULE_DEVICE_TABLE(usb, pctv_usb_ids);

static int pctv_usb_probe(struct usb_interface *intf,
			  const struct usb_device_id *id)
{
	return pctv320cx_probe(intf, id);
}

static void pctv_usb_disconnect(struct usb_interface *intf)
{
	pctv320cx_disconnect(intf);
}

static struct usb_driver pctv_usb_driver = {
	.name = KBUILD_MODNAME,
	.probe = pctv_usb_probe,
	.disconnect = pctv_usb_disconnect,
	.id_table = pctv_usb_ids,
	.supports_autosuspend = 1,
};

int pctv_usb_register(void)
{
	return usb_register(&pctv_usb_driver);
}

void pctv_usb_unregister(void)
{
	usb_deregister(&pctv_usb_driver);
}

/* ------------------------------------------------------------- small shims */

void pctv_dev_set_drvdata(struct device *dev, void *data)
{
	dev_set_drvdata(dev, data);
}

void *pctv_dev_get_drvdata(struct device *dev)
{
	return dev_get_drvdata(dev);
}

unsigned int pctv_usb_rcvbulkpipe(struct usb_device *dev, u8 endpoint)
{
	return usb_rcvbulkpipe(dev, endpoint);
}

unsigned int pctv_usb_sndbulkpipe(struct usb_device *dev, u8 endpoint)
{
	return usb_sndbulkpipe(dev, endpoint);
}

void pctv_usb_fill_bulk_urb(struct urb *urb, struct usb_device *dev,
			    unsigned int pipe, void *buffer, int length,
			    usb_complete_t complete, void *context)
{
	usb_fill_bulk_urb(urb, dev, pipe, buffer, length, complete, context);
}

u8 pctv_usb_endpoint_num(const struct usb_endpoint_descriptor *ep)
{
	return usb_endpoint_num(ep);
}

bool pctv_usb_endpoint_is_in(const struct usb_endpoint_descriptor *ep)
{
	return usb_endpoint_dir_in(ep);
}

u32 pctv_usb_endpoint_maxpkt(const struct usb_endpoint_descriptor *ep)
{
	return usb_endpoint_maxp(ep);
}

const struct firmware *pctv_request_fw(struct device *dev, const char *name)
{
	const struct firmware *fw = NULL;

	if (request_firmware(&fw, name, dev))
		return NULL;
	return fw;
}

void pctv_release_fw(struct device *dev, const struct firmware *fw)
{
	release_firmware(fw);
}


struct usb_device *pctv_interface_to_usbdev(struct usb_interface *intf)
{
	return interface_to_usbdev(intf);
}

void pctv_dev_notice(struct device *dev, const char *msg)
{
	dev_notice(dev, "%s\n", msg);
}

void pctv_dev_warn(struct device *dev, const char *msg)
{
	dev_warn(dev, "%s\n", msg);
}

unsigned int pctv_gfp_kernel(void)
{
	return GFP_KERNEL;
}

unsigned int pctv_gfp_atomic(void)
{
	return GFP_ATOMIC;
}
