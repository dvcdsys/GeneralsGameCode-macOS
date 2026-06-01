# Graphics Improvements Plan (Generals / Zero Hour, macOS Metal port)

Доповнення до [MACOS_PORT_PLAN.md](MACOS_PORT_PLAN.md). Збираю ідеї, як покращити
картинку гри **без переписування рендеру**, від «нульової роботи» до невеликих
правок у Metal-бекенді. Старт — DX8-era forward renderer, фіксована RTS-камера.

---

## Рівень 1 — Нульова робота (зовнішні інструменти)

Не торкаються коду гри, працюють як інжектори / overlay / драйверні tweaks.

- **ReShade** (Windows) — пост-процес інжектор поверх D3D/Vulkan:
  - SMAA / FXAA замість MSAA
  - CAS (Contrast Adaptive Sharpening, AMD)
  - AmbientObscurance / MXAO (екранний AO)
  - HDR tone-mapping, color grading через LUT
  - На macOS прямого аналога нема; через MoltenVK + `vkBasalt` теоретично можливо
- **Lossless Scaling** (Steam, ~$7, Windows) — FSR / LS1 / власні апскейлери
  + frame generation поверх будь-якої гри. Рендериш у 720p → 1440p +
  інтерпольовані кадри. Гра нічого не знає.
- **DXVK / dgVoodoo2** (Windows) — перетранслятор DX8/9 → Vulkan/DX11.
  Сам по собі картинку не покращує, але знімає CPU bottleneck і відкриває шлях
  до force-AA / force-aniso через драйвер.
- **Драйверні tweaks** (NVIDIA Control Panel / AMD Adrenalin):
  - 16x anisotropic filtering
  - Transparency AA
  - Negative LOD bias
  - Image Sharpening

> Для нашого macOS-порту цей рівень обмежено корисний (немає ReShade-аналога).
> Залишаємо як reference для Windows-користувачів.

---

## Рівень 2 — Низька робота (заміна ассетів, community-вже-зробив)

Не торкаються коду, але потребують offline pipeline.

- **HD texture packs** для Generals / Zero Hour існують (ModDB, GenLauncher).
  Заміна `.tga` / `.dds` на 2-4x роздільності — без коду.
- **Upscale текстур через ESRGAN / Real-ESRGAN**:
  - Batch-прогін усього `Art/Textures` через `chaiNNer` або `cupscale`
  - Великий стрибок якості на UI та unit-iconах
  - Один раз — вічно
- **Заміна skybox / terrain detail** — community-моди (Rise of the Reds,
  Contra) мають кращі ассети; можна підглянути ліцензії / попросити дозвіл.

---

## Рівень 3 — Невелика робота в Metal-бекенді

Це наш домен. Враховуючи поточні комміти (texture cache, color write mask,
half-texel bias) — ці правки органічно лягають у те, що вже є.

### 3.1. MSAA через Metal (пріоритет #1)

```objc
MTLRenderPassDescriptor *pass = ...;
pass.colorAttachments[0].texture = msaaTexture;       // .type2DMultisample
pass.colorAttachments[0].resolveTexture = displayTex; // resolve target
pass.colorAttachments[0].storeAction = .multisampleResolve;
```

- На Apple Silicon MSAA працює в **tile memory** — майже безкоштовно
  (немає write-back в DRAM між сампл-точками)
- 4x — солодке місце; 8x на M-series теж тягне
- Миттєвий приріст якості країв юнітів і terrain seams
- Складність: ~50 рядків (pipeline descriptor + render pass + resolve)

### 3.2. Anisotropic filtering (пріоритет #1)

```objc
MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];
s.maxAnisotropy = 16;
```

- Один рядок на sampler, який використовується для terrain / unit textures
- Текстури terrain на віддалі перестають мазатись
- Нульова вартість на сучасних GPU

### 3.3. CAS — Contrast Adaptive Sharpening (пріоритет #2)

- AMD відкрив код під MIT; це **~30 рядків MSL-шейдера**
- Запускається як останній full-screen пост-пас
- Дає той самий «crisp» ефект, що sharpening у DLSS, без апскейлу
- Reference: https://gpuopen.com/fidelityfx-cas/

### 3.4. SMAA 1x (пріоритет #3)

- Open-source, один full-screen пас (3 sub-passes: edge / blend / neighborhood)
- Замінює відсутній MSAA на тонких лініях UI / unit outlines
- Альтернатива якщо MSAA з якоїсь причини не запрацює

### 3.5. Bloom / tone-mapping (пріоритет #3)

- Простий 2-pass Gaussian blur по яскравих пікселях + additive
- ~100 рядків MSL + один render target половини роздільності
- Picture стає «сучаснішою» без зміни ассетів
- Обережно з UI — bloom на іконках виглядає погано, треба маска / окремий шар

### 3.6. MetalFX Spatial Upscaling (пріоритет #3)

```objc
MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
d.inputWidth = 1280; d.inputHeight = 720;
d.outputWidth = 2560; d.outputHeight = 1440;
id<MTLFXSpatialScaler> s = [d newSpatialScalerWithDevice:device];
```

- ~5 рядків API, Metal 3 (macOS 13+)
- Temporal-варіант **не вийде** без motion vectors (у нас їх нема)
- Spatial — render в 1440p, upscale до 4K; майже безкоштовно на M-series
- Корисно для retina-екранів; на FullHD виграш менший

---

## Рекомендований порядок впровадження

1. **MSAA 4x + 16x aniso** — 10 рядків коду, найбільший видимий приріст на
   Apple Silicon, органічно ляже в поточний render path
2. **CAS pass** — 30 рядків шейдера, картинка стає «різкою», single full-screen
   pass — легко вимкнути
3. **ESRGAN-апскейл текстур** — окремий offline крок, не торкається коду,
   паралельно з кодовою роботою
4. **SMAA / Bloom / MetalFX Spatial** — якщо захочеться далі

Перші три кроки разом дають ~80% візуального ефекту «ремастера» за день-два
роботи в Metal-бекенді.

---

## Ризики / нотатки

- **UI**: Generals використовує 2D atlas-based UI. Будь-який пост-ефект
  (bloom, CAS, sharpening) треба застосовувати **до** композиції UI або з
  маскою, інакше іконки / шрифт постраждають. Подивитись де у render-graph
  малюється UI — швидше за все окремий пас наприкінці кадру.
- **Half-texel bias** (комміт `4723dcdac`): seam-fix на UI atlas може
  взаємодіяти з sharpening — перевірити після інтеграції CAS.
- **Texture cache** (комміт `a7b38c7fe`): aniso і MSAA нічого не ламають у
  level-0 surface cache; partial updates все ще валідні.
- **Color write mask** (комміт `1ba84e4de`): soft water edges — перевірити,
  що MSAA resolve не «з'їдає» альфу на цих пасах.

---

## Що НЕ робити (свідомо)

- **DLSS / FSR 2 / MetalFX Temporal** — потребують motion vectors і depth;
  для DX8-era forward renderer це переписування геометричного passу. Не
  вартує.
- **Deferred lighting / PBR** — повний рендер-rewrite, виходить за межі порту.
- **Real-time GI / ray tracing** — те саме, плюс ассети не PBR-ready.

Усе перераховане вище — це шлях «нова гра», а не «покращити existing».
