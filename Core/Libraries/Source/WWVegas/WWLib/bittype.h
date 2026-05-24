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

/* $Header: /G/wwlib/bittype.h 4     4/02/99 1:37p Eric_c $ */
/***************************************************************************
 ***                  Confidential - Westwood Studios                    ***
 ***************************************************************************
 *                                                                         *
 *                 Project Name : Voxel Technology                         *
 *                                                                         *
 *                    File Name : BITTYPE.h                                *
 *                                                                         *
 *                   Programmer : Greg Hjelstrom                           *
 *                                                                         *
 *                   Start Date : 02/24/97                                 *
 *                                                                         *
 *                  Last Update : February 24, 1997 [GH]                   *
 *                                                                         *
 *-------------------------------------------------------------------------*
 * Functions:                                                              *
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

#pragma once

typedef unsigned char	uint8;
typedef unsigned short	uint16;
#if defined(__APPLE__)
// TheSuperHackers @fix macOS-port: on LP64 (macOS/arm64) `long` is 64-bit, but a
// type named uint32/sint32 MUST be exactly 32 bits — it backs the on-disk binary
// layout of W3D structs (W3dMeshHeader3Struct etc.) and the chunk header
// (ChunkHeader in chunkio.h). With `long` here, sizeof(uint32)==8 doubled every
// such struct, so cload.Read(&hdr, sizeof(hdr)) over-read and desynced the W3D
// stream → "Old format mesh" / garbage chunk ids → NO 3D model could load.
// `unsigned int` is 32-bit on both macOS-LP64 and Win32 (where long is also 32),
// so this is a no-op for the Windows build. Same class as the TGA2Footer fix.
typedef unsigned int	uint32;
typedef unsigned int    uint;

typedef signed char		sint8;
typedef signed short		sint16;
typedef signed int		sint32;
typedef signed int      sint;
#else
typedef unsigned long	uint32;
typedef unsigned int    uint;

typedef signed char		sint8;
typedef signed short		sint16;
typedef signed long		sint32;
typedef signed int      sint;
#endif

typedef float				float32;
typedef double				float64;

typedef unsigned long   DWORD;
typedef unsigned short	WORD;
typedef unsigned char   BYTE;
typedef int             BOOL;
typedef unsigned short	USHORT;
typedef const char *		LPCSTR;
typedef unsigned int    UINT;
typedef unsigned long   ULONG;

#if defined(_MSC_VER) && _MSC_VER < 1300
#ifndef _WCHAR_T_DEFINED
typedef unsigned short wchar_t;
#define _WCHAR_T_DEFINED
#endif
#endif
