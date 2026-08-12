#import "info.h"
#import "primitives.h"
#import "translation.h"
#import "kernel.h"
#import "util.h"
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach-o/dyld.h>

static CFNumberRef CFNUM64(uint64_t value)
{
	return CFNumberCreate(NULL, kCFNumberSInt64Type, (void *)&value);
}

uint64_t IOSurfaceRootUserClient_get_surfaceClientById(uint64_t rootUserClient, uint32_t surfaceId)
{
	uint64_t surfaceClientsArray = kread_ptr(rootUserClient + 0x118);
	return kread_ptr(surfaceClientsArray + (sizeof(uint64_t)*surfaceId));
}

uint64_t IOSurfaceClient_get_surface(uint64_t surfaceClient)
{
	return kread_ptr(surfaceClient + 0x40);
}

uint64_t IOSurfaceSendRight_get_surface(uint64_t surfaceSendRight)
{
	if (gPrimitives.krwMinSafeReadSize > 0x8) {
		uint32_t zoneSize = 0x30;
		uint64_t readOffset = zoneSize - gPrimitives.krwMinSafeReadSize;
		uint8_t buf[gPrimitives.krwMinSafeReadSize];

		kreadbuf(surfaceSendRight + readOffset, buf, sizeof(buf));
		return UNSIGN_PTR(*(uint64_t *)&buf[0x18 - readOffset]);
	}
	return kread_ptr(surfaceSendRight + 0x18);
}

uint64_t IOSurface_get_ranges(uint64_t surface)
{
	return kread_ptr(surface + koffsetof(IOSurface, ranges));
}

void IOSurface_set_ranges(uint64_t surface, uint64_t ranges)
{
	kwrite64(surface + koffsetof(IOSurface, ranges), ranges);
}

uint64_t IOSurface_get_memoryDescriptor(uint64_t surface)
{
	return kread_ptr(surface + koffsetof(IOSurface, memoryDescriptor));
}

uint64_t IOMemoryDescriptor_get_ranges(uint64_t memoryDescriptor)
{
	return kread_ptr(memoryDescriptor + 0x60);
}

void IOMemoryDescriptor_set_ranges(uint64_t memoryDescriptor, uint64_t ranges)
{
	kwrite64(memoryDescriptor + 0x60, ranges);
}

uint64_t IOMemorydescriptor_get_size(uint64_t memoryDescriptor)
{
	return kread64(memoryDescriptor + 0x50);
}

void IOMemoryDescriptor_set_size(uint64_t memoryDescriptor, uint64_t size)
{
	kwrite64(memoryDescriptor + 0x50, size);
}

void IOMemoryDescriptor_set_wired(uint64_t memoryDescriptor, bool wired)
{
	kwrite8(memoryDescriptor + 0x88, wired);
}

uint32_t IOMemoryDescriptor_get_flags(uint64_t memoryDescriptor)
{
	return kread32(memoryDescriptor + 0x20);
}

void IOMemoryDescriptor_set_flags(uint64_t memoryDescriptor, uint32_t flags)
{
	kwrite8(memoryDescriptor + 0x20, flags);
}

void IOMemoryDescriptor_set_memRef(uint64_t memoryDescriptor, uint64_t memRef)
{
	kwrite64(memoryDescriptor + 0x28, memRef);
}

uint64_t IOSurface_get_rangeCount(uint64_t surface)
{
	return kread_ptr(surface + koffsetof(IOSurface, rangeCount));
}

void IOSurface_set_rangeCount(uint64_t surface, uint32_t rangeCount)
{
	kwrite32(surface + koffsetof(IOSurface, rangeCount), rangeCount);
}

uint64_t IOSurface_port_getSendRight(mach_port_t surfaceMachPort)
{
	uint64_t surfaceSendRight = task_get_ipc_port_kobject(task_self(), surfaceMachPort);
	if (koffsetof(IOMachPort, object)) {
		if (gPrimitives.krwMinSafeReadSize > 0x8) {
			uint32_t zoneSize = koffsetof(IOMachPort, object) + 0x8;
			uint64_t readOffset = zoneSize - gPrimitives.krwMinSafeReadSize;
			uint8_t buf[gPrimitives.krwMinSafeReadSize];

			kreadbuf(surfaceSendRight + readOffset, buf, sizeof(buf));
			surfaceSendRight = UNSIGN_PTR(*(uint64_t *)&buf[sizeof(buf) - 0x8]);
		}
		else {
			surfaceSendRight = kread_ptr(surfaceSendRight + koffsetof(IOMachPort, object));
		}
	}
	return surfaceSendRight;
}

static mach_port_t IOSurface_map_getSurfacePort(uint64_t magic, uint32_t cacheMode)
{
	NSMutableDictionary *properties = [@{
		(__bridge NSString *)kIOSurfaceWidth : @120,
		(__bridge NSString *)kIOSurfaceHeight : @120,
		(__bridge NSString *)kIOSurfaceBytesPerElement : @4,
	} mutableCopy];
	if (cacheMode != 0) {
		properties[(__bridge NSString *)kIOSurfaceCacheMode] = @(cacheMode);
	}
	IOSurfaceRef surfaceRef = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
	mach_port_t port = IOSurfaceCreateMachPort(surfaceRef);
	*((uint64_t *)IOSurfaceGetBaseAddress(surfaceRef)) = magic;
	IOSurfaceDecrementUseCount(surfaceRef);
	CFRelease(surfaceRef);
	return port;
}

struct IOSurfaceMapCleanup {
	uint64_t descriptor;
	uint64_t originalRanges;
	uint64_t *fakeRanges;
};

static struct IOSurfaceMapCleanup *gMapCleanups;
static unsigned gMapCleanupCount;

int IOSurface_map_withCacheMode(uint64_t pa, uint64_t size, void **uaddr, uint32_t cacheMode)
{
	mach_port_t surfaceMachPort = IOSurface_map_getSurfacePort(1337, cacheMode);
	if (!MACH_PORT_VALID(surfaceMachPort)) return -1;

	uint64_t surfaceSendRight = IOSurface_port_getSendRight(surfaceMachPort);
	uint64_t surface = IOSurfaceSendRight_get_surface(surfaceSendRight);
	uint64_t desc = IOSurface_get_memoryDescriptor(surface);
	uint64_t ranges = IOMemoryDescriptor_get_ranges(desc);
	if (!surface || !desc || !ranges) {
		mach_port_deallocate(mach_task_self(), surfaceMachPort);
		return -1;
	}

	if (gPrimitives.krwMinSafeReadSize > 0x10) {
		uint64_t *fakeRanges = malloc(2 * sizeof(uint64_t));
		if (!fakeRanges) {
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			return -1;
		}
		fakeRanges[0] = pa;
		fakeRanges[1] = size;

		uint64_t fakeRangesKaddr = phystokv(vtophys(ttep_self(), (uint64_t)fakeRanges));
		IOMemoryDescriptor_set_ranges(desc, fakeRangesKaddr);

		gMapCleanups = realloc(gMapCleanups, ++gMapCleanupCount * sizeof(*gMapCleanups));
		gMapCleanups[gMapCleanupCount - 1] = (struct IOSurfaceMapCleanup){ desc, ranges, fakeRanges };
	}
	else {
		kwrite64(ranges, pa);
		kwrite64(ranges + 8, size);
	}

	IOMemoryDescriptor_set_size(desc, size);

	kwrite64(desc + 0x70, 0);
	kwrite64(desc + 0x18, 0);
	kwrite64(desc + 0x90, 0);

	IOMemoryDescriptor_set_wired(desc, true);

	uint32_t flags = IOMemoryDescriptor_get_flags(desc);
	IOMemoryDescriptor_set_flags(desc, (flags & ~0x410) | 0x20);

	IOMemoryDescriptor_set_memRef(desc, 0);

	IOSurfaceRef mappedSurfaceRef = IOSurfaceLookupFromMachPort(surfaceMachPort);
	if (!mappedSurfaceRef) {
		mach_port_deallocate(mach_task_self(), surfaceMachPort);
		return -1;
	}
	*uaddr = IOSurfaceGetBaseAddress(mappedSurfaceRef);
	if (!*uaddr) {
		mach_port_deallocate(mach_task_self(), surfaceMachPort);
		return -1;
	}

	if (@available(iOS 17.0, *)) {
	}
	else {
		vm_prot_t cur_prot, max_prot;
		kern_return_t kr = vm_remap(mach_task_self(), (vm_address_t *)uaddr, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)*uaddr, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
		assert(kr == KERN_SUCCESS);
	}

	return 0;
}

int IOSurface_map(uint64_t pa, uint64_t size, void **uaddr)
{
	return IOSurface_map_withCacheMode(pa, size, uaddr, 0);
}

void IOSurface_map_cleanup(void)
{
	for (unsigned i = 0; i < gMapCleanupCount; i++) {
		IOMemoryDescriptor_set_ranges(gMapCleanups[i].descriptor, gMapCleanups[i].originalRanges);
		free(gMapCleanups[i].fakeRanges);
	}
	free(gMapCleanups);
	gMapCleanups = NULL;
	gMapCleanupCount = 0;
}

static mach_port_t IOSurface_kalloc_getSurfacePort(uint64_t size)
{
	uint64_t allocSize = 0x10;
	uint64_t *addressRangesBuf = (uint64_t *)malloc(size);
	memset(addressRangesBuf, 0, size);
	addressRangesBuf[0] = (uint64_t)malloc(allocSize);
	addressRangesBuf[1] = allocSize;
	NSData *addressRanges = [NSData dataWithBytes:addressRangesBuf length:size];
	free(addressRangesBuf);

	IOSurfaceRef surfaceRef = IOSurfaceCreate((__bridge CFDictionaryRef)@{
		@"IOSurfaceAllocSize" : @(allocSize),
		@"IOSurfaceAddressRanges" : addressRanges,
	});
	mach_port_t port = IOSurfaceCreateMachPort(surfaceRef);
	IOSurfaceDecrementUseCount(surfaceRef);
	return port;
}

static mach_port_t IOSurface_kalloc_getSurfacePort_16up(uint64_t size)
{
	uint64_t rangesAlignedSize = ((size + 0xf) & ~0xf);

	static vm_size_t dummyPageSize = 0x4000;
	static vm_address_t dummyPage = 0;
	if (dummyPage == 0) {
		vm_allocate(mach_task_self(), &dummyPage, dummyPageSize, VM_FLAGS_ANYWHERE);
	}

	uint64_t *userspaceRanges = malloc(rangesAlignedSize);
	for (int i = 0; i < (rangesAlignedSize / sizeof(uint64_t)); i += 2) {
		userspaceRanges[i] = dummyPage;
		userspaceRanges[i+1] = dummyPageSize;
	}

	CFDataRef userspaceRangesData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)userspaceRanges, rangesAlignedSize);
	free(userspaceRanges);

	CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
	CFNumberRef dummyPageSizeNum = CFNUM64(dummyPageSize);
	CFDictionarySetValue(dict, CFSTR("IOSurfaceAllocSize"), dummyPageSizeNum);
	CFDictionarySetValue(dict, CFSTR("IOSurfaceAddressRanges"), userspaceRangesData);

	IOSurfaceRef surfaceRef = IOSurfaceCreate(dict);
	mach_port_t port = surfaceRef ? IOSurfaceCreateMachPort(surfaceRef) : MACH_PORT_NULL;
	if (surfaceRef) IOSurfaceDecrementUseCount(surfaceRef);
	CFRelease(userspaceRangesData);
	CFRelease(dummyPageSizeNum);
	CFRelease(dict);
	return port;
}

static uint64_t IOSurface_kalloc_16up(uint64_t size, bool leak)
{
	if (size > 0x10000) return 0;

	while (true) {
		mach_port_t surfaceMachPort = IOSurface_kalloc_getSurfacePort_16up(size);
		if (!MACH_PORT_VALID(surfaceMachPort)) return 0;

		uint64_t surfaceSendRight = IOSurface_port_getSendRight(surfaceMachPort);
		uint64_t surface = IOSurfaceSendRight_get_surface(surfaceSendRight);
		uint64_t va = IOSurface_get_ranges(surface);
		uint64_t vaSize = IOSurface_get_rangeCount(surface) * 0x10;

		if (vaSize < size || va == 0) {
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			continue;
		}

		if (leak) {
			IOSurface_set_ranges(surface, 0);
			IOSurface_set_rangeCount(surface, 0);
		}

		return va;
	}
}

uint64_t IOSurface_kalloc(uint64_t size, bool leak)
{
	if (@available(iOS 16.0, *)) {
		return IOSurface_kalloc_16up(size, leak);
	}

	while (true) {
		uint64_t allocSize = max(size, 0x10000);
		mach_port_t surfaceMachPort = IOSurface_kalloc_getSurfacePort(allocSize);
		uint64_t surfaceSendRight = IOSurface_port_getSendRight(surfaceMachPort);
		uint64_t surface = IOSurfaceSendRight_get_surface(surfaceSendRight);
		uint64_t va = IOSurface_get_ranges(surface);

		if (kvtophys(va + allocSize) != 0) {
			mach_port_deallocate(mach_task_self(), surfaceMachPort);
			continue;
		}
		if (va == 0) continue;

		if (leak) {
			IOSurface_set_ranges(surface, 0);
			IOSurface_set_rangeCount(surface, 0);
		}
		return va + (allocSize - size);
	}
}

int IOSurface_kalloc_global(uint64_t *addr, uint64_t size)
{
	uint64_t alloc = IOSurface_kalloc(size, true);
	if (alloc != 0) {
		*addr = alloc;
		return 0;
	}
	return -1;
}

int IOSurface_kalloc_local(uint64_t *addr, uint64_t size)
{
	uint64_t alloc = IOSurface_kalloc(size, false);
	if (alloc != 0) {
		*addr = alloc;
		return 0;
	}
	return -1;
}

void libjailbreak_IOSurface_primitives_init(void)
{
	IOSurfaceRef surfaceRef = IOSurfaceCreate((__bridge CFDictionaryRef)@{
		(__bridge NSString *)kIOSurfaceWidth : @120,
		(__bridge NSString *)kIOSurfaceHeight : @120,
		(__bridge NSString *)kIOSurfaceBytesPerElement : @4,
	});
	if (!surfaceRef) {
		char execPath[PATH_MAX];
		uint32_t execPathSize = PATH_MAX;
		_NSGetExecutablePath(execPath, &execPathSize);
		printf("Failed to initialize IOSurface primitives, add \"IOSurfaceRootUserClient\" to the \"com.apple.security.exception.iokit-user-client-class\" dictionary of the entitlements from \"%s\" to fix this. Due to this, the kalloc, kmap and kcall primitives will not work.\n", execPath);
		return;
	}
	CFRelease(surfaceRef);

	gPrimitives.kmap = IOSurface_map;
	gPrimitives.kalloc_global = IOSurface_kalloc_global;
	gPrimitives.kalloc_local  = IOSurface_kalloc_local;
}
