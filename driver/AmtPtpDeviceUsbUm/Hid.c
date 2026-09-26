// Hid.c: HID-related routine

#include <driver.h>
#include <StaticHidRegistry.h>
#include "Hid.tmh"

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
AmtPtpGetHidDescriptor(
	_In_ WDFDEVICE Device,
	_In_ WDFREQUEST Request
)
{

	NTSTATUS        status   = STATUS_SUCCESS;
	PDEVICE_CONTEXT pContext = DeviceGetContext(Device);
	size_t			szHidDescriptor = 0;
	WDFMEMORY       RequestMemory;
	PHID_DESCRIPTOR pSelectedHidDescriptor = NULL;

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Entry"
	);

	status = WdfRequestRetrieveOutputMemory(
		Request, 
		&RequestMemory
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! WdfRequestRetrieveOutputBuffer failed with %!STATUS!", 
			status
		);
		return status;
	}

	switch (pContext->DeviceDescriptor.idProduct) {
		case USB_DEVICE_ID_APPLE_WELLSPRING3_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING3_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING3_JIS:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Request HID Report Descriptor for MacBook Family, Wellspring 3 Series"
			);

			szHidDescriptor = AmtPtp3DefaultHidDescriptor.bLength;
			pSelectedHidDescriptor = &AmtPtp3DefaultHidDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING5_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING5_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING5_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING5A_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING5A_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING5A_JIS:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Request HID Report Descriptor for MacBook Family, Wellspring 5/5A Series"
			);

			szHidDescriptor = AmtPtp5DefaultHidDescriptor.bLength;
			pSelectedHidDescriptor = &AmtPtp5DefaultHidDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING6_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING6_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING6_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING6A_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING6A_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING6A_JIS:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Request HID Report Descriptor for MacBook Family, Wellspring 6/6A Series"
			);

			szHidDescriptor = AmtPtp6DefaultHidDescriptor.bLength;
			pSelectedHidDescriptor = &AmtPtp6DefaultHidDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING7_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING7_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING7_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING7A_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING7A_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING7A_JIS:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Request HID Report Descriptor for MacBook Family, Wellspring 7/7A Series"
			);

			szHidDescriptor = AmtPtp7aDefaultHidDescriptor.bLength;
			pSelectedHidDescriptor = &AmtPtp7aDefaultHidDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING8_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING8_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING8_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING9_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING9_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING9_ISO:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Request HID Report Descriptor for MacBook Family, Wellspring 8 Series"
			);

			szHidDescriptor = AmtPtp8DefaultHidDescriptor.bLength;
			pSelectedHidDescriptor = &AmtPtp8DefaultHidDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2:
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_USBC:
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_27A7_A:
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_27A7_B:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Request HID Report Descriptor for Apple Magic Trackpad 2 Family"
			);

			szHidDescriptor = AmtPtpMt2DefaultHidDescriptor.bLength;
			pSelectedHidDescriptor = &AmtPtpMt2DefaultHidDescriptor;
			break;
		}
	}

	if (pSelectedHidDescriptor != NULL && szHidDescriptor > 0) {
		status = WdfMemoryCopyFromBuffer(
			RequestMemory,
			0,
			(PVOID) pSelectedHidDescriptor,
			szHidDescriptor
		);

		if (!NT_SUCCESS(status)) {
			TraceEvents(
				TRACE_LEVEL_ERROR,
				TRACE_DRIVER,
				"%!FUNC! WdfMemoryCopyFromBuffer failed with %!STATUS!",
				status
			);
			goto exit;
		}

		WdfRequestSetInformation(
			Request,
			szHidDescriptor
		);
	}
	else {
		TraceEvents(
			TRACE_LEVEL_WARNING,
			TRACE_DRIVER,
			"%!FUNC! Device HID registry is not found"
		);
		TraceLoggingWrite(
			g_hAmtPtpDeviceTraceProvider,
			EVENT_DEVICE_IDENTIFICATION,
			TraceLoggingString("AmtPtpGetHidDescriptor", "Routine"),
			TraceLoggingUInt16(pContext->DeviceDescriptor.idProduct, "idProduct"),
			TraceLoggingString(EVENT_DEVICE_ID_SUBTYPE_HIDREG_NOTFOUND, EVENT_DRIVER_FUNC_SUBTYPE)
		);
		status = STATUS_INVALID_DEVICE_STATE;
		goto exit;
	}

exit:
	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Exit"
	);
	return status;
}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
AmtPtpGetDeviceAttribs(
	_In_ WDFDEVICE Device,
	_In_ WDFREQUEST Request
)
{

	NTSTATUS               status = STATUS_SUCCESS;
	PDEVICE_CONTEXT        pContext = DeviceGetContext(Device);
	PHID_DEVICE_ATTRIBUTES pDeviceAttributes = NULL;

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Entry"
	);

	status = WdfRequestRetrieveOutputBuffer(
		Request, 
		sizeof(HID_DEVICE_ATTRIBUTES), 
		&pDeviceAttributes, 
		NULL
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! WdfRequestRetrieveOutputBuffer failed with %!STATUS!", 
			status
		);
		goto exit;
	}

	pDeviceAttributes->Size          = sizeof(HID_DEVICE_ATTRIBUTES);
	pDeviceAttributes->ProductID     = pContext->DeviceDescriptor.idProduct;
	// Okay here's one thing: we cannot report the real ID here, otherwise there's will be some great conflict with the USB/BT driver.
	// Therefore Vendor ID is changed to a hardcoded number
	pDeviceAttributes->VendorID      = DEVICE_VID;
	pDeviceAttributes->VersionNumber = DEVICE_VERSION;
	
	WdfRequestSetInformation(
		Request, 
		sizeof(HID_DEVICE_ATTRIBUTES)
	);

exit:
	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Exit"
	);

	return status;
}

// Scratch copy of the Magic Trackpad 2 report descriptor used when the axes have
// to be swapped for 90/270 degree rotation. It is rebuilt from the pristine
// template on every descriptor request, so it cannot accumulate changes.
static UCHAR g_Mt2RotatedReportDescriptor[sizeof(AmtPtpMt2ReportDescriptor)];

// Swaps the X and Y axis declarations of the Magic Trackpad 2 report descriptor
// (logical maxima 7612/5065 and physical maxima 1600/1149). With the axes swapped
// the descriptor matches the coordinate mapping AmtPtpRotateContact applies for
// 90/270 degree rotation, so the rotated surface keeps the pad's real physical
// proportions instead of being stretched by the aspect ratio.
//
// The padded buffer is always a pristine copy of AmtPtpMt2ReportDescriptor, so
// this is applied at most once per descriptor request. The byte pattern is the
// exact X/Y block emitted by AAPL_MAGIC_TRACKPAD2_PTP_FINGER_COLLECTION_1/2 and
// occurs once per finger collection (five in total).
static VOID
AmtPtpSwapXyAxesInReportDescriptor(
	_Inout_updates_bytes_(Length) UCHAR* Descriptor,
	_In_ size_t Length
)
{
	static const UCHAR XyBlock[] = {
		0x26, 0xBC, 0x1D,   // LOGICAL_MAXIMUM 7612 (X)
		0x75, 0x10,         // REPORT_SIZE 16
		0x55, 0x0E,         // UNIT_EXPONENT -2
		0x65, 0x11,         // UNIT 0x11 (SI Length: cm)
		0x09, 0x30,         // USAGE X
		0x46, 0x40, 0x06,   // PHYSICAL_MAXIMUM 1600 (X)
		0x95, 0x01,         // REPORT_COUNT 1
		0x81, 0x02,         // INPUT (Data,Var,Abs)
		0x46, 0x7D, 0x04,   // PHYSICAL_MAXIMUM 1149 (Y)
		0x26, 0xC9, 0x13,   // LOGICAL_MAXIMUM 5065 (Y)
		0x09, 0x31,         // USAGE Y
		0x81, 0x02          // INPUT (Data,Var,Abs)
	};
	static const UCHAR XyBlockRotated[] = {
		0x26, 0xC9, 0x13,   // LOGICAL_MAXIMUM 5065 (X)
		0x75, 0x10,
		0x55, 0x0E,
		0x65, 0x11,
		0x09, 0x30,
		0x46, 0x7D, 0x04,   // PHYSICAL_MAXIMUM 1149 (X)
		0x95, 0x01,
		0x81, 0x02,
		0x46, 0x40, 0x06,   // PHYSICAL_MAXIMUM 1600 (Y)
		0x26, 0xBC, 0x1D,   // LOGICAL_MAXIMUM 7612 (Y)
		0x09, 0x31,
		0x81, 0x02
	};
	size_t i, j;
	BOOLEAN match;

	if (Length < sizeof(XyBlock)) {
		return;
	}

	for (i = 0; i + sizeof(XyBlock) <= Length; i++) {
		match = TRUE;
		for (j = 0; j < sizeof(XyBlock); j++) {
			if (Descriptor[i + j] != XyBlock[j]) {
				match = FALSE;
				break;
			}
		}

		if (match) {
			RtlCopyMemory(Descriptor + i, XyBlockRotated, sizeof(XyBlockRotated));
			i += sizeof(XyBlock) - 1;
		}
	}
}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
AmtPtpGetReportDescriptor(
	_In_ WDFDEVICE Device,
	_In_ WDFREQUEST Request
)
{
	
	NTSTATUS               status = STATUS_SUCCESS;
	PDEVICE_CONTEXT        pContext = DeviceGetContext(Device);
	size_t			       szHidDescriptor = 0;
	WDFMEMORY              RequestMemory;
	PHID_REPORT_DESCRIPTOR pSelectedHidDescriptor = NULL;
	ULONG                  rotation = 0;

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Entry"
	);

	status = WdfRequestRetrieveOutputMemory(
		Request, 
		&RequestMemory
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! WdfRequestRetrieveOutputBuffer failed with %!STATUS!", 
			status
		);
		goto exit;
	}

	switch (pContext->DeviceDescriptor.idProduct) {
		case USB_DEVICE_ID_APPLE_WELLSPRING3_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING3_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING3_JIS:
		{
			szHidDescriptor = AmtPtp3DefaultHidDescriptor.DescriptorList[0].wReportLength;
			pSelectedHidDescriptor = AmtPtp3ReportDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING5_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING5_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING5_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING5A_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING5A_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING5A_JIS:
		{
			szHidDescriptor = AmtPtp5DefaultHidDescriptor.DescriptorList[0].wReportLength;
			pSelectedHidDescriptor = AmtPtp5ReportDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING6_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING6_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING6_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING6A_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING6A_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING6A_JIS:
		{
			szHidDescriptor = AmtPtp6DefaultHidDescriptor.DescriptorList[0].wReportLength;
			pSelectedHidDescriptor = AmtPtp6ReportDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING7_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING7_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING7_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING7A_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING7A_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING7A_JIS:
		{
			szHidDescriptor = AmtPtp7aDefaultHidDescriptor.DescriptorList[0].wReportLength;
			pSelectedHidDescriptor = AmtPtp7aReportDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_WELLSPRING8_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING8_ISO:
		case USB_DEVICE_ID_APPLE_WELLSPRING8_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING9_JIS:
		case USB_DEVICE_ID_APPLE_WELLSPRING9_ANSI:
		case USB_DEVICE_ID_APPLE_WELLSPRING9_ISO:
		{
			szHidDescriptor = AmtPtp8DefaultHidDescriptor.DescriptorList[0].wReportLength;
			pSelectedHidDescriptor = AmtPtp8ReportDescriptor;
			break;
		}
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2:
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_USBC:
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_27A7_A:
		case USB_DEVICE_ID_APPLE_MAGICTRACKPAD2_27A7_B:
		{
			szHidDescriptor = AmtPtpMt2DefaultHidDescriptor.DescriptorList[0].wReportLength;
			pSelectedHidDescriptor = AmtPtpMt2ReportDescriptor;

			// The host caches the report descriptor, so a rotation change only
			// takes effect after the device is restarted (MtTrackpad.ps1 rotate
			// does that). 90/270 need the axes swapped; 0/180 need the raw one.
			rotation = ReadSettingValue(L"Rotation", 0);
			if (rotation == 90 || rotation == 270) {
				RtlCopyMemory(
					g_Mt2RotatedReportDescriptor,
					AmtPtpMt2ReportDescriptor,
					sizeof(AmtPtpMt2ReportDescriptor)
				);
				AmtPtpSwapXyAxesInReportDescriptor(
					g_Mt2RotatedReportDescriptor,
					sizeof(g_Mt2RotatedReportDescriptor)
				);
				pSelectedHidDescriptor = g_Mt2RotatedReportDescriptor;
			}
			break;
		}
	}

	if (pSelectedHidDescriptor != NULL && szHidDescriptor > 0) {
		status = WdfMemoryCopyFromBuffer(
			RequestMemory,
			0,
			(PVOID) pSelectedHidDescriptor,
			szHidDescriptor
		);

		if (!NT_SUCCESS(status)) {
			TraceEvents(
				TRACE_LEVEL_ERROR,
				TRACE_DRIVER,
				"%!FUNC! WdfMemoryCopyFromBuffer failed with %!STATUS!",
				status
			);
			return status;
		}

		WdfRequestSetInformation(
			Request,
			szHidDescriptor
		);
	}
	else if (szHidDescriptor == 0) {
		status = STATUS_INVALID_DEVICE_STATE;
		TraceEvents(
			TRACE_LEVEL_WARNING,
			TRACE_DRIVER,
			"%!FUNC! Device HID report length is zero"
		);
		goto exit;
	}
	else {
		TraceEvents(
			TRACE_LEVEL_WARNING,
			TRACE_DRIVER,
			"%!FUNC! Device HID registry is not found"
		);
		TraceLoggingWrite(
			g_hAmtPtpDeviceTraceProvider,
			EVENT_DEVICE_IDENTIFICATION,
			TraceLoggingString("AmtPtpGetReportDescriptor", "Routine"),
			TraceLoggingUInt16(pContext->DeviceDescriptor.idProduct, "idProduct"),
			TraceLoggingString(EVENT_DEVICE_ID_SUBTYPE_HIDREG_NOTFOUND, EVENT_DRIVER_FUNC_SUBTYPE)
		);
		status = STATUS_INVALID_DEVICE_STATE;
		goto exit;
	}

exit:
	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Exit"
	);
	return status;
}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
AmtPtpGetStrings(
	_In_ WDFDEVICE Device,
	_In_ WDFREQUEST Request
)
{
	
	NTSTATUS               status = STATUS_SUCCESS;
	PDEVICE_CONTEXT        pContext = DeviceGetContext(Device);
	void                   *pStringBuffer = NULL;
	WDFMEMORY              memHandle;
	USHORT                 wcharCount;
	size_t                 actualSize;
	UCHAR                  strIndex;

	ULONG                  inputValue;
	WDFMEMORY              inputMemory;
	size_t                 inputBufferLength;
	PVOID                  inputBuffer;
	ULONG                  languageId, stringId;

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Entry"
	);

	status = WdfRequestRetrieveInputMemory(
		Request, 
		&inputMemory
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_INFORMATION,
			TRACE_DRIVER, 
			"%!FUNC! WdfRequestRetrieveInputMemory failed with status %!STATUS!",
			status
		);
		return status;
	}

	inputBuffer = WdfMemoryGetBuffer(
		inputMemory, 
		&inputBufferLength
	);

	//
	// make sure buffer is big enough.
	//
	if (inputBufferLength < sizeof(ULONG)) {
		status = STATUS_INVALID_BUFFER_SIZE;
		TraceEvents(
			TRACE_LEVEL_INFORMATION, 
			TRACE_DRIVER, 
			"%!FUNC! GetStringId: invalid input buffer. size %d, expect %d",
			(int)inputBufferLength, 
			(int) sizeof(ULONG)
		);
		return status;
	}

	inputValue = (*(PULONG)inputBuffer);
	stringId = (inputValue & 0x0ffff);
	languageId = (inputValue >> 16);

	// Get actual string from USB device
	switch (stringId)
	{
		case HID_STRING_ID_IMANUFACTURER:
			strIndex = pContext->DeviceDescriptor.iManufacturer;
			break;
		case HID_STRING_ID_IPRODUCT:
			strIndex = pContext->DeviceDescriptor.iProduct;
			break;
		case HID_STRING_ID_ISERIALNUMBER:
			strIndex = pContext->DeviceDescriptor.iSerialNumber;
			break;
		default:
			TraceEvents(
				TRACE_LEVEL_WARNING, 
				TRACE_DRIVER, 
				"%!FUNC! gets invalid string type"
			);
			return status;
	}

	status = WdfUsbTargetDeviceAllocAndQueryString(
		pContext->UsbDevice, 
		WDF_NO_OBJECT_ATTRIBUTES, 
		&memHandle, 
		&wcharCount, 
		strIndex, 
		(USHORT) languageId
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, "%!FUNC! WdfUsbTargetDeviceAllocAndQueryString failed with %!STATUS!", 
			status
		);
		return status;
	}

	status = WdfRequestRetrieveOutputBuffer(
		Request, 
		wcharCount * sizeof(WCHAR), 
		&pStringBuffer, 
		&actualSize
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! WdfMemoryCopyFromBuffer failed with %!STATUS!", 
			status
		);
		return status;
	}

	WdfMemoryCopyToBuffer(
		memHandle,
		0, 
		&pStringBuffer, 
		actualSize
	);

	WdfRequestSetInformation(
		Request, 
		actualSize
	);

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Exit"
	);
	return status;

}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
RequestGetHidXferPacketToReadFromDevice(
	_In_  WDFREQUEST        Request,
	_Out_ HID_XFER_PACKET  *Packet
)
{

	//
	// Driver need to write to the output buffer (so that App can read from it)
	//
	//   Report Buffer: Output Buffer
	//   Report Id    : Input Buffer
	//

	NTSTATUS                status;
	WDFMEMORY               inputMemory;
	WDFMEMORY               outputMemory;
	size_t                  inputBufferLength;
	size_t                  outputBufferLength;
	PVOID                   inputBuffer;
	PVOID                   outputBuffer;

	//
	// Get report Id from input buffer
	//
	status = WdfRequestRetrieveInputMemory(
		Request, 
		&inputMemory
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! WdfRequestRetrieveInputMemory failed with %!STATUS!", 
			status
		);
		return status;
	}
	inputBuffer = WdfMemoryGetBuffer(
		inputMemory, 
		&inputBufferLength
	);

	if (inputBufferLength < sizeof(UCHAR)) {
		status = STATUS_INVALID_BUFFER_SIZE;
		TraceEvents(
			TRACE_LEVEL_ERROR,
			TRACE_DRIVER,
			"%!FUNC! WdfRequestRetrieveInputMemory: invalid input buffer. size %d, expect %d",
			(int) inputBufferLength, 
			(int) sizeof(UCHAR)
		);
		return status;
	}

	Packet->reportId = *(PUCHAR) inputBuffer;

	//
	// Get report buffer from output buffer
	//
	status = WdfRequestRetrieveOutputMemory(
		Request, 
		&outputMemory
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR,
			TRACE_DRIVER,
			"%!FUNC! WdfRequestRetrieveOutputMemory failed with %!STATUS!",
			status
		);
		return status;
	}

	outputBuffer = WdfMemoryGetBuffer(
		outputMemory, 
		&outputBufferLength
	);

	Packet->reportBuffer = (PUCHAR) outputBuffer;
	Packet->reportBufferLen = (ULONG) outputBufferLength;

	return status;

}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
RequestGetHidXferPacketToWriteToDevice(
	_In_  WDFREQUEST        Request,
	_Out_ HID_XFER_PACKET  *Packet
)
{

	//
	// Driver need to read from the input buffer (which was written by App)
	//
	//   Report Buffer: Input Buffer
	//   Report Id    : Output Buffer Length
	//
	// Note that the report id is not stored inside the output buffer, as the
	// driver has no read-access right to the output buffer, and trying to read
	// from the buffer will cause an access violation error.
	//
	// The workaround is to store the report id in the OutputBufferLength field,
	// to which the driver does have read-access right.
	//

	NTSTATUS                status;
	WDFMEMORY               inputMemory;
	WDFMEMORY               outputMemory;
	size_t                  inputBufferLength;
	size_t                  outputBufferLength;
	PVOID                   inputBuffer;

	//
	// Get report Id from output buffer length
	//
	status = WdfRequestRetrieveOutputMemory(
		Request, 
		&outputMemory
	);
	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR,
			TRACE_DRIVER,
			"%!FUNC! WdfRequestRetrieveOutputMemory failed with %!STATUS!",
			status
		);
		return status;
	}
	WdfMemoryGetBuffer(
		outputMemory, 
		&outputBufferLength
	);
	Packet->reportId = (UCHAR) outputBufferLength;

	//
	// Get report buffer from input buffer
	//
	status = WdfRequestRetrieveInputMemory(
		Request, 
		&inputMemory
	);
	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR,
			TRACE_DRIVER,
			"%!FUNC! WdfRequestRetrieveInputMemory failed with %!STATUS!",
			status
		);
		return status;
	}
	inputBuffer = WdfMemoryGetBuffer(
		inputMemory, 
		&inputBufferLength
	);

	Packet->reportBuffer = (PUCHAR) inputBuffer;
	Packet->reportBufferLen = (ULONG) inputBufferLength;

	return status;

}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
AmtPtpReportFeatures(
	_In_ WDFDEVICE Device,
	_In_ WDFREQUEST Request
)
{

	NTSTATUS status;
	PDEVICE_CONTEXT deviceContext;
	HID_XFER_PACKET packet;
	size_t reportSize;

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Entry"
	);

	status = STATUS_SUCCESS;
	deviceContext = DeviceGetContext(Device);

	status = RequestGetHidXferPacketToReadFromDevice(
		Request, 
		&packet
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! RequestGetHidXferPacketToReadFromDevice failed with status %!STATUS!", 
			status
		);
		goto exit;
	}

	switch (packet.reportId)
	{
		case REPORTID_DEVICE_CAPS:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_DEVICE_CAPS is requested"
			);

			// Size sanity check
			reportSize = sizeof(PTP_DEVICE_CAPS_FEATURE_REPORT);
			if (packet.reportBufferLen < reportSize) {
				status = STATUS_INVALID_BUFFER_SIZE;
				TraceEvents(
					TRACE_LEVEL_ERROR, 
					TRACE_DRIVER, 
					"%!FUNC! Report buffer is too small"
				);
				goto exit;
			}

			PPTP_DEVICE_CAPS_FEATURE_REPORT capsReport = (PPTP_DEVICE_CAPS_FEATURE_REPORT) packet.reportBuffer;

			capsReport->MaximumContactPoints = PTP_MAX_CONTACT_POINTS;
			capsReport->ButtonType = PTP_BUTTON_TYPE_CLICK_PAD;
			capsReport->ReportID = REPORTID_DEVICE_CAPS;

			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_DEVICE_CAPS has maximum contact points of %d", 
				capsReport->MaximumContactPoints
			);
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_DEVICE_CAPS has touchpad type %d", 
				capsReport->ButtonType
			);
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_DEVICE_CAPS is fulfilled"
			);

			WdfRequestSetInformation(
				Request, 
				reportSize
			);
			break;
		}
		case REPORTID_PTPHQA:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_PTPHQA is requested"
			);

			// Size sanity check
			reportSize = sizeof(PTP_DEVICE_HQA_CERTIFICATION_REPORT);
			if (packet.reportBufferLen < reportSize) {
				status = STATUS_INVALID_BUFFER_SIZE;
				TraceEvents(
					TRACE_LEVEL_ERROR, 
					TRACE_DRIVER, 
					"%!FUNC! Report buffer is too small."
				);
				goto exit;
			}

			PPTP_DEVICE_HQA_CERTIFICATION_REPORT certReport = (PPTP_DEVICE_HQA_CERTIFICATION_REPORT) packet.reportBuffer;

			*certReport->CertificationBlob = DEFAULT_PTP_HQA_BLOB;
			certReport->ReportID = REPORTID_PTPHQA;

			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_PTPHQA is fulfilled"
			);

			WdfRequestSetInformation(
				Request, 
				reportSize
			);
			break;
		}
		case REPORTID_UMAPP_CONF:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Report REPORTID_UMAPP_CONF is requested"
			);

			// Size sanity check
			reportSize = sizeof(PTP_USERMODEAPP_CONF_REPORT);
			if (packet.reportBufferLen < reportSize) {
				status = STATUS_INVALID_BUFFER_SIZE;
				TraceEvents(
					TRACE_LEVEL_ERROR,
					TRACE_DRIVER,
					"%!FUNC! Report buffer is too small."
				);
				goto exit;
			}

			PPTP_USERMODEAPP_CONF_REPORT confReport = (PPTP_USERMODEAPP_CONF_REPORT)packet.reportBuffer;
			
			confReport->ReportID = REPORTID_UMAPP_CONF;
			confReport->MultipleContactSizeQualificationLevel = deviceContext->MuContactSizeQualLevel;
			confReport->SingleContactSizeQualificationLevel = deviceContext->SgContactSizeQualLevel;
			confReport->PressureQualificationLevel = deviceContext->PressureQualLevel;

			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Report REPORTID_UMAPP_CONF is fulfilled"
			);

			WdfRequestSetInformation(
				Request,
				reportSize
			);
			break;
		}
		default:
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Unsupported type %d is requested", 
				packet.reportId
			);

			status = STATUS_NOT_SUPPORTED;
			goto exit;
	}
exit:
	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Exit"
	);
	return status;

}

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS
AmtPtpSetFeatures(
	_In_ WDFDEVICE Device,
	_In_ WDFREQUEST Request
)
{

	NTSTATUS        status;
	HID_XFER_PACKET packet;
	PDEVICE_CONTEXT deviceContext;

	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Entry"
	);

	status = STATUS_SUCCESS;
	deviceContext = DeviceGetContext(Device);

	status = RequestGetHidXferPacketToWriteToDevice(
		Request, 
		&packet
	);

	if (!NT_SUCCESS(status)) {
		TraceEvents(
			TRACE_LEVEL_ERROR, 
			TRACE_DRIVER, 
			"%!FUNC! RequestGetHidXferPacketToWriteToDevice failed with status %!STATUS!", 
			status
		);
		goto exit;
	}

	switch (packet.reportId)
	{
		case REPORTID_REPORTMODE:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_REPORTMODE is requested"
			);

			PPTP_DEVICE_INPUT_MODE_REPORT devInputMode = (PPTP_DEVICE_INPUT_MODE_REPORT) packet.reportBuffer;

			// Get current WellSpring mode
			BOOL bWellspringMode = FALSE;
			status = AmtPtpGetWellspringMode(
				deviceContext,
				&bWellspringMode
			);

			if (!NT_SUCCESS(status)) {

				TraceEvents(
					TRACE_LEVEL_ERROR,
					TRACE_DRIVER,
					"%!FUNC! -> AmtPtpGetWellspringMode failed with status %!STATUS!",
					status
				);
				goto exit;

			}

			switch (devInputMode->Mode)
			{
				case PTP_COLLECTION_MOUSE:
				{

					TraceEvents(
						TRACE_LEVEL_INFORMATION,
						TRACE_DRIVER,
						"%!FUNC! Report REPORTID_REPORTMODE requested Mouse Input"
					);

					if (bWellspringMode) {

						status = AmtPtpSetWellspringMode(
							deviceContext,
							FALSE
						);

						if (!NT_SUCCESS(status)) {
							TraceEvents(
								TRACE_LEVEL_ERROR,
								TRACE_DRIVER,
								"%!FUNC! -> AmtPtpSetWellspringMode failed with status %!STATUS!",
								status
							);
							goto exit;
						}

					}
				
					break;

				}
				case PTP_COLLECTION_WINDOWS:
				{

					TraceEvents(
						TRACE_LEVEL_INFORMATION,
						TRACE_DRIVER,
						"%!FUNC! Report REPORTID_REPORTMODE requested Windows PTP Input"
					);

					if (!bWellspringMode) {
						
						status = AmtPtpSetWellspringMode(
							deviceContext,
							TRUE
						);

						if (!NT_SUCCESS(status)) {
							TraceEvents(
								TRACE_LEVEL_ERROR,
								TRACE_DRIVER,
								"%!FUNC! -> AmtPtpSetWellspringMode failed with status %!STATUS!",
								status
							);
							goto exit;
						}

					}

					break;

				}
			}

			WdfRequestSetInformation(
				Request, 
				sizeof(PTP_DEVICE_INPUT_MODE_REPORT)
			);

			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_REPORTMODE is fulfilled"
			);
			break;
		}
		case REPORTID_FUNCSWITCH:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_FUNCSWITCH is requested"
			);
			PPTP_DEVICE_SELECTIVE_REPORT_MODE_REPORT secInput = (PPTP_DEVICE_SELECTIVE_REPORT_MODE_REPORT) packet.reportBuffer;

			deviceContext->IsButtonReportOn = secInput->ButtonReport;
			deviceContext->IsSurfaceReportOn = secInput->SurfaceReport;

			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_FUNCSWITCH requested Button = %d, Surface = %d",
				secInput->ButtonReport, 
				secInput->SurfaceReport
			);

			WdfRequestSetInformation(
				Request,
				sizeof(PTP_DEVICE_SELECTIVE_REPORT_MODE_REPORT)
			);

			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER, 
				"%!FUNC! Report REPORTID_FUNCSWITCH is fulfilled"
			);
			break;
		}
		case REPORTID_UMAPP_CONF:
		{
			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Report REPORTID_UMAPP_CONF is requested"
			);
			PPTP_USERMODEAPP_CONF_REPORT umConfInput = (PPTP_USERMODEAPP_CONF_REPORT) packet.reportBuffer;

			// Set value
			deviceContext->SgContactSizeQualLevel = umConfInput->SingleContactSizeQualificationLevel;
			deviceContext->MuContactSizeQualLevel = umConfInput->MultipleContactSizeQualificationLevel;
			deviceContext->PressureQualLevel = umConfInput->PressureQualificationLevel;

			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Report REPORTID_UMAPP_CONF requested PressureQual = %d, SgSize = %d, MuSize = %d",
				umConfInput->PressureQualificationLevel,
				umConfInput->SingleContactSizeQualificationLevel,
				umConfInput->MultipleContactSizeQualificationLevel
			);

			// Report back
			WdfRequestSetInformation(
				Request,
				sizeof(PTP_USERMODEAPP_CONF_REPORT)
			);

			TraceEvents(
				TRACE_LEVEL_INFORMATION,
				TRACE_DRIVER,
				"%!FUNC! Report REPORTID_UMAPP_CONF is fulfilled"
			);

			break;
		}
		default:
			TraceEvents(
				TRACE_LEVEL_INFORMATION, 
				TRACE_DRIVER, 
				"%!FUNC! Unsupported type %d is requested",
				packet.reportId
			);
			status = STATUS_NOT_SUPPORTED;
			goto exit;
	}

exit:
	TraceEvents(
		TRACE_LEVEL_INFORMATION, 
		TRACE_DRIVER, 
		"%!FUNC! Exit"
	);
	return STATUS_SUCCESS;

}