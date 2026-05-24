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

// FILE: CocoaKeyboard.h //////////////////////////////////////////////////////
// TheSuperHackers @port macOS keyboard device. Replaces DirectInputKeyboard
// (DirectInput is unavailable on macOS). Pulls key events from the Cocoa/Metal
// window's NSEvent queue (exposed by the Metal backend) and maps macOS virtual
// key codes (kVK_*) onto the engine's DirectInput-scancode KeyDefType values.
///////////////////////////////////////////////////////////////////////////////

#pragma once

#include "GameClient/Keyboard.h"

// class CocoaKeyboard --------------------------------------------------------
class CocoaKeyboard : public Keyboard
{
public:
	CocoaKeyboard();
	virtual ~CocoaKeyboard() override;

	virtual void init() override;
	virtual void reset() override;
	virtual void update() override;
	virtual Bool getCapsState() override;

protected:
	virtual void getKey( KeyboardIO *key ) override;
};
