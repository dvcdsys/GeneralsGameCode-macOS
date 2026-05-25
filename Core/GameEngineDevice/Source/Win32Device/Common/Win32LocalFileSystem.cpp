/*
**	Command & Conquer Generals Zero Hour(tm)
**	Copyright 2025 Electronic Arts Inc.
**
**	This program is free software: you can redistribute it and/or modify
**	it under the terms of the GNU General Public License as published by
**	the Free Software Foundation, either version 3 of the License, or
**	(at your option) any later version.
**
**	This program is distributed in the hope that it will be useful,
**	but WITHOUT ANY WARRANTY; without even the implied warranty of
**	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**	GNU General Public License for more details.
**
**	You should have received a copy of the GNU General Public License
**	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

////////////////////////////////////////////////////////////////////////////////
//																																						//
//  (c) 2001-2003 Electronic Arts Inc.																				//
//																																						//
////////////////////////////////////////////////////////////////////////////////

///////// Win32LocalFileSystem.cpp /////////////////////////
// Bryan Cleveland, August 2002
////////////////////////////////////////////////////////////

#include <windows.h>
#include "Common/AsciiString.h"
#include "Common/GameMemory.h"
#include "Common/PerfTimer.h"
#include "Win32Device/Common/Win32LocalFileSystem.h"
#include "Win32Device/Common/Win32LocalFile.h"
#include <io.h>

#if defined(__APPLE__)
#include <filesystem>
#include <algorithm>
#include <string>
#include <cstring>

// TheSuperHackers @port macOS 2026-05-25
// On macOS we still instantiate Win32LocalFileSystem (Win32GameEngine is the
// only GameEngine subclass), but POSIX fopen rejects Windows-style backslash
// paths. Some hardcoded engine paths (notably data\\Scripts\\SkirmishScripts.scb)
// arrive here verbatim and silently fail to open — leaving the AI player
// without team templates and triggering an immediate "AI defeated".
//
// Normalise the same way StdLocalFileSystem already does: backslash to slash,
// then if the literal path does not exist, walk it component-by-component
// matching case-insensitively. Returns an empty path on failure.
static std::filesystem::path apple_fixWindowsPath(const char* filename, Int access)
{
    std::string fixedFilename(filename);
    std::replace(fixedFilename.begin(), fixedFilename.end(), '\\', '/');
    std::filesystem::path path(std::move(fixedFilename));

    std::error_code ec;
    if (std::filesystem::exists(path, ec))
        return path;

    // For writes, accept as long as the parent directory exists (file will be created).
    if ((access & File::WRITE) && std::filesystem::exists(path.parent_path(), ec))
        return path;

    // Walk the path; for each component, prefer literal match, otherwise
    // fall back to case-insensitive directory lookup.
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
                if (::strcasecmp(entry.path().filename().string().c_str(), p.string().c_str()) == 0)
                {
                    pathFixedPart = entry.path().filename();
                    break;
                }
            }
        }

        if (pathFixedPart.empty())
        {
            if (!(access & File::WRITE))
                return std::filesystem::path();
            pathFixed = p;
        }

        pathFixed /= pathFixedPart;
        pathCurrent /= p;
    }
    return pathFixed;
}
#endif

Win32LocalFileSystem::Win32LocalFileSystem() : LocalFileSystem()
{
}

Win32LocalFileSystem::~Win32LocalFileSystem() {
}

//DECLARE_PERF_TIMER(Win32LocalFileSystem_openFile)
File * Win32LocalFileSystem::openFile(const Char *filename, Int access, size_t bufferSize)
{
	//USE_PERF_TIMER(Win32LocalFileSystem_openFile)

	// sanity check
	if (strlen(filename) <= 0) {
		return nullptr;
	}

	if (access & File::WRITE) {
		// if opening the file for writing, we need to make sure the directory is there
		// before we try to create the file.
		AsciiString string;
		string = filename;
		AsciiString token;
		AsciiString dirName;
		string.nextToken(&token, "\\/");
		dirName = token;
		while ((token.find('.') == nullptr) || (string.find('.') != nullptr)) {
			createDirectory(dirName);
			string.nextToken(&token, "\\/");
			dirName.concat('\\');
			dirName.concat(token);
		}
	}

	// TheSuperHackers @fix Mauller 21/04/2025 Create new file handle when necessary to prevent memory leak
	Win32LocalFile *file = newInstance( Win32LocalFile );

#if defined(__APPLE__)
	std::filesystem::path normalized = apple_fixWindowsPath(filename, access);
	if (normalized.empty()) {
		deleteInstance(file);
		return nullptr;
	}
	const char* openName = normalized.c_str();
#else
	const char* openName = filename;
#endif

	if (file->open(openName, access, bufferSize) == FALSE) {
		deleteInstance(file);
		file = nullptr;
	} else {
		file->deleteOnClose();
	}

// this will also need to play nice with the STREAMING type that I added, if we ever enable this

// srj sez: this speeds up INI loading, but makes BIG files unusable.
// don't enable it without further tweaking.
//
// unless you like running really slowly.
//	if (!(access&File::WRITE)) {
//		// Return a ramfile.
//		RAMFile *ramFile = newInstance( RAMFile );
//		if (ramFile->open(file)) {
//			file->close(); // is deleteonclose, so should delete.
//			ramFile->deleteOnClose();
//			return ramFile;
//		}	else {
//			ramFile->close();
//			deleteInstance(ramFile);
//		}
//	}

	return file;
}

void Win32LocalFileSystem::update()
{
}

void Win32LocalFileSystem::init()
{
}

void Win32LocalFileSystem::reset()
{
}

//DECLARE_PERF_TIMER(Win32LocalFileSystem_doesFileExist)
Bool Win32LocalFileSystem::doesFileExist(const Char *filename) const
{
	//USE_PERF_TIMER(Win32LocalFileSystem_doesFileExist)
#if defined(__APPLE__)
	// Same Windows-path normalisation as openFile, so callers that probe
	// existence with backslash paths (e.g. via TheFileSystem) get a truthful
	// answer instead of false-negative.
	std::filesystem::path normalized = apple_fixWindowsPath(filename, 0);
	if (normalized.empty())
		return FALSE;
	std::error_code ec;
	return std::filesystem::exists(normalized, ec) ? TRUE : FALSE;
#else
	if (_access(filename, 0) == 0) {
		return TRUE;
	}
	return FALSE;
#endif
}

void Win32LocalFileSystem::getFileListInDirectory(const AsciiString& currentDirectory, const AsciiString& originalDirectory, const AsciiString& searchName, FilenameList & filenameList, Bool searchSubdirectories) const
{
	HANDLE fileHandle = nullptr;
	WIN32_FIND_DATA findData;

	AsciiString asciisearch;
	asciisearch = originalDirectory;
	asciisearch.concat(currentDirectory);
	asciisearch.concat(searchName);

	Bool done = FALSE;

	fileHandle = FindFirstFile(asciisearch.str(), &findData);
	done = (fileHandle == INVALID_HANDLE_VALUE);

	while (!done)	{
		if (!(findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
				(strcmp(findData.cFileName, ".") != 0 && strcmp(findData.cFileName, "..") != 0)) {
			// if we haven't already, add this filename to the list.
				// a stl set should only allow one copy of each filename
				AsciiString newFilename;
				newFilename = originalDirectory;
				newFilename.concat(currentDirectory);
				newFilename.concat(findData.cFileName);
				if (filenameList.find(newFilename) == filenameList.end()) {
					filenameList.insert(newFilename);
				}
		}

		done = (FindNextFile(fileHandle, &findData) == 0);
	}
	FindClose(fileHandle);

	if (searchSubdirectories) {
		AsciiString subdirsearch;
		subdirsearch = originalDirectory;
		subdirsearch.concat(currentDirectory);
		subdirsearch.concat("*.");
		fileHandle = FindFirstFile(subdirsearch.str(), &findData);
		done = fileHandle == INVALID_HANDLE_VALUE;

		while (!done) {
			if ((findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
					(strcmp(findData.cFileName, ".") != 0 && strcmp(findData.cFileName, "..") != 0)) {

					AsciiString tempsearchstr;
					tempsearchstr.concat(currentDirectory);
					tempsearchstr.concat(findData.cFileName);
					tempsearchstr.concat('\\');

					// recursively add files in subdirectories if required.
					getFileListInDirectory(tempsearchstr, originalDirectory, searchName, filenameList, searchSubdirectories);
			}

			done = (FindNextFile(fileHandle, &findData) == 0);
		}

		FindClose(fileHandle);
	}

}

Bool Win32LocalFileSystem::getFileInfo(const AsciiString& filename, FileInfo *fileInfo) const
{
	WIN32_FIND_DATA findData;
	HANDLE findHandle = nullptr;
	findHandle = FindFirstFile(filename.str(), &findData);

	if (findHandle == INVALID_HANDLE_VALUE) {
		return FALSE;
	}

	fileInfo->timestampHigh = findData.ftLastWriteTime.dwHighDateTime;
	fileInfo->timestampLow = findData.ftLastWriteTime.dwLowDateTime;
	fileInfo->sizeHigh = findData.nFileSizeHigh;
	fileInfo->sizeLow = findData.nFileSizeLow;

	FindClose(findHandle);

	return TRUE;
}

Bool Win32LocalFileSystem::createDirectory(AsciiString directory)
{
	if ((!directory.isEmpty()) && (directory.getLength() < _MAX_DIR)) {
		return (CreateDirectory(directory.str(), nullptr) != 0);
	}
	return FALSE;
}

AsciiString Win32LocalFileSystem::normalizePath(const AsciiString& filePath) const
{
	DWORD retval = GetFullPathNameA(filePath.str(), 0, nullptr, nullptr);
	if (retval == 0)
	{
		DEBUG_LOG(("Unable to determine buffer size for normalized file path. Error=(%u).", GetLastError()));
		return AsciiString::TheEmptyString;
	}

	AsciiString normalizedFilePath;
	retval = GetFullPathNameA(filePath.str(), retval, normalizedFilePath.getBufferForRead(retval - 1), nullptr);
	if (retval == 0)
	{
		DEBUG_LOG(("Unable to normalize file path '%s'. Error=(%u).", filePath.str(), GetLastError()));
		return AsciiString::TheEmptyString;
	}

	return normalizedFilePath;
}
