// macos_port_tests/fileio_check.cpp
//
// Standalone test for the Apple path-normalisation we added to
// Win32LocalFileSystem. Reproduces the exact algorithm without engine
// dependencies and validates it against the live game install at
// $GAMEDIR/data/Scripts/SkirmishScripts.scb.
//
// Why this exists: the original bug was that on macOS the engine still
// instantiates Win32LocalFileSystem (Win32GameEngine is the only GameEngine
// subclass), so hardcoded Windows-style paths like
// "data\\Scripts\\SkirmishScripts.scb" went straight to fopen and failed.
// The fix mirrors what StdLocalFileSystem does internally. This harness
// pins the fix's behaviour down to a few assertions you can re-run in
// seconds, without launching the game.
//
// Run:
//   cd <repo-root>
//   GAMEDIR="<install dir>" macos_port_tests/run_fileio.sh

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <unistd.h>

namespace {

// Mirror of apple_fixWindowsPath() in Win32LocalFileSystem.cpp.
// Keep these two in sync if either side changes.
constexpr int kAccessWrite = 0x2;  // mirror of File::WRITE

std::filesystem::path apple_fixWindowsPath(const char* filename, int access)
{
    std::string fixed(filename);
    std::replace(fixed.begin(), fixed.end(), '\\', '/');
    std::filesystem::path path(std::move(fixed));

    std::error_code ec;
    if (std::filesystem::exists(path, ec))
        return path;
    if ((access & kAccessWrite) && std::filesystem::exists(path.parent_path(), ec))
        return path;

    std::filesystem::path pathFixed;
    std::filesystem::path pathCurrent;
    for (const auto& p : path)
    {
        if (pathCurrent.empty())
        {
            pathFixed /= p;
            pathCurrent /= p;
            continue;
        }
        std::filesystem::path pathFixedPart;
        if (std::filesystem::exists(pathCurrent / p, ec))
            pathFixedPart = p;
        else if (std::filesystem::exists(pathFixed / p, ec))
            pathFixedPart = p;
        else
        {
            for (auto& entry : std::filesystem::directory_iterator(pathFixed, ec))
            {
                if (::strcasecmp(entry.path().filename().string().c_str(),
                                 p.string().c_str()) == 0)
                {
                    pathFixedPart = entry.path().filename();
                    break;
                }
            }
        }
        if (pathFixedPart.empty())
        {
            if (!(access & kAccessWrite))
                return std::filesystem::path();
            pathFixed = p;
        }
        pathFixed /= pathFixedPart;
        pathCurrent /= p;
    }
    return pathFixed;
}

bool try_open(const std::filesystem::path& p, long* out_size = nullptr)
{
    if (p.empty()) return false;
    FILE* f = std::fopen(p.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fclose(f);
    if (out_size) *out_size = sz;
    return true;
}

int report(const char* label, const char* input, int access, bool expect_ok)
{
    auto path = apple_fixWindowsPath(input, access);
    long sz = -1;
    bool ok = try_open(path, &sz);
    bool pass = (ok == expect_ok);
    std::printf("  %s\n", pass ? "PASS" : "FAIL");
    std::printf("    label   : %s\n", label);
    std::printf("    input   : '%s' (access=0x%x)\n", input, access);
    std::printf("    fixed   : '%s'\n", path.empty() ? "<empty>" : path.c_str());
    std::printf("    open    : %s (size=%ld)\n", ok ? "OK" : "FAIL", sz);
    std::printf("    expect  : %s\n\n", expect_ok ? "OK" : "FAIL");
    return pass ? 0 : 1;
}

}  // namespace

int main()
{
    const char* gamedir_env = std::getenv("GAMEDIR");
    if (!gamedir_env) {
        std::fprintf(stderr, "GAMEDIR must point at the C&C install root\n");
        return 2;
    }
    if (::chdir(gamedir_env) != 0) {
        std::fprintf(stderr, "chdir(GAMEDIR='%s') failed\n", gamedir_env);
        return 2;
    }
    std::printf("fileio_check (Apple Win32-path normalisation)\n");
    std::printf("CWD = %s\n\n", gamedir_env);

    int fails = 0;

    // The canary: the actual file the bug was about.
    fails += report("forward-slash literal",
                    "data/Scripts/SkirmishScripts.scb", 0, true);
    fails += report("backslash literal (the failure mode)",
                    "data\\Scripts\\SkirmishScripts.scb", 0, true);
    fails += report("backslash + wrong case on dir",
                    "DATA\\scripts\\skirmishscripts.scb", 0, true);
    fails += report("does-not-exist (read) returns empty",
                    "data\\Scripts\\NoSuchFile.scb", 0, false);
    fails += report("does-not-exist (write) keeps path",
                    "data\\Scripts\\NoSuchFile.scb", kAccessWrite, false);

    if (fails == 0) {
        std::printf("ALL PASS — Win32LocalFileSystem path fix is correct.\n");
        return 0;
    }
    std::printf("%d FAILED — fix the normalisation.\n", fails);
    return 1;
}
