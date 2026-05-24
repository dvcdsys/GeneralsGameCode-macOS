// Milestone 1 smoke test for the DX8 -> Metal backend.
//
// Proves the Metal window + device works end-to-end via the public DX8 COM API,
// without booting the full game (which currently stops earlier at data loading):
//   Direct3DCreate8 -> CreateDevice -> ~120 frames of Clear(cornflower) + Present.
//
// A 1024x768 window should appear and clear to cornflower blue, then exit.
//
// macOS-only.

#include <windows.h>   // osdep_compat shim
#include <d3d8.h>

#include <cstdio>

int main()
{
    IDirect3D8* d3d = Direct3DCreate8(D3D_SDK_VERSION);
    if (!d3d) {
        std::printf("[smoketest] Direct3DCreate8 returned null\n");
        return 1;
    }
    std::printf("[smoketest] Direct3DCreate8 OK, adapters=%u\n", d3d->GetAdapterCount());

    D3DDISPLAYMODE mode{};
    d3d->GetAdapterDisplayMode(D3DADAPTER_DEFAULT, &mode);
    std::printf("[smoketest] display mode %ux%u fmt=%d\n", mode.Width, mode.Height, (int)mode.Format);

    D3DCAPS8 caps{};
    d3d->GetDeviceCaps(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, &caps);
    std::printf("[smoketest] caps MaxTextureWidth=%lu MaxTextureBlendStages=%lu\n",
                (unsigned long)caps.MaxTextureWidth, (unsigned long)caps.MaxTextureBlendStages);

    D3DPRESENT_PARAMETERS pp{};
    pp.BackBufferWidth  = 1024;
    pp.BackBufferHeight = 768;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferCount  = 1;
    pp.SwapEffect       = D3DSWAPEFFECT_DISCARD;
    pp.Windowed         = TRUE;
    pp.EnableAutoDepthStencil = TRUE;
    pp.AutoDepthStencilFormat = D3DFMT_D24S8;

    IDirect3DDevice8* device = nullptr;
    HRESULT hr = d3d->CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, nullptr,
                                   D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (hr != D3D_OK || !device) {
        std::printf("[smoketest] CreateDevice failed hr=0x%08lx\n", (unsigned long)hr);
        d3d->Release();
        return 1;
    }
    std::printf("[smoketest] CreateDevice OK -- window should be visible. Running ~120 frames...\n");

    // Cornflower blue (the classic D3D clear color): ARGB 0xFF6495ED.
    const D3DCOLOR cornflower = 0xFF6495ED;

    for (int frame = 0; frame < 120; ++frame) {
        device->Clear(0, nullptr, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER, cornflower, 1.0f, 0);
        device->BeginScene();
        device->EndScene();
        device->Present(nullptr, nullptr, nullptr, nullptr);
    }

    std::printf("[smoketest] done, releasing.\n");
    device->Release();
    d3d->Release();
    return 0;
}
