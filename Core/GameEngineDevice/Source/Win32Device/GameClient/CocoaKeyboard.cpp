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

// FILE: CocoaKeyboard.cpp ////////////////////////////////////////////////////
// TheSuperHackers @port macOS keyboard device — see CocoaKeyboard.h.
///////////////////////////////////////////////////////////////////////////////

// macOS-only device. Compiles to nothing elsewhere so it can be listed
// unconditionally in CMake without breaking the Windows/MSVC build.
#if defined(__APPLE__)

#include <windows.h>   // osdep_compat shim (timeGetTime, types)

#include "Common/Debug.h"
#include "GameClient/KeyDefs.h"
#include "GameClient/Keyboard.h"
#include "GameClient/GameWindowManager.h"   // TheWindowManager, GWM_IME_CHAR
#include "Win32Device/GameClient/CocoaKeyboard.h"

// The Metal backend (Objective-C++) owns the Cocoa window and captures NSEvents.
extern "C" int MetalInput_PollKey(int* macKeyCode, int* down);
extern "C" int MetalInput_CapsOn(void);
extern "C" int MetalInput_PollChar(unsigned int* outChar);

// macOS virtual key codes (kVK_*, from <Carbon/HIToolbox/Events.h>). Hardcoded
// to avoid pulling Carbon into this translation unit; these are stable.
namespace {
enum {
	kVK_A=0x00, kVK_S=0x01, kVK_D=0x02, kVK_F=0x03, kVK_H=0x04, kVK_G=0x05,
	kVK_Z=0x06, kVK_X=0x07, kVK_C=0x08, kVK_V=0x09, kVK_B=0x0B, kVK_Q=0x0C,
	kVK_W=0x0D, kVK_E=0x0E, kVK_R=0x0F, kVK_Y=0x10, kVK_T=0x11,
	kVK_1=0x12, kVK_2=0x13, kVK_3=0x14, kVK_4=0x15, kVK_6=0x16, kVK_5=0x17,
	kVK_Equal=0x18, kVK_9=0x19, kVK_7=0x1A, kVK_Minus=0x1B, kVK_8=0x1C, kVK_0=0x1D,
	kVK_RightBracket=0x1E, kVK_O=0x1F, kVK_U=0x20, kVK_LeftBracket=0x21,
	kVK_I=0x22, kVK_P=0x23, kVK_Return=0x24, kVK_L=0x25, kVK_J=0x26,
	kVK_Quote=0x27, kVK_K=0x28, kVK_Semicolon=0x29, kVK_Backslash=0x2A,
	kVK_Comma=0x2B, kVK_Slash=0x2C, kVK_N=0x2D, kVK_M=0x2E, kVK_Period=0x2F,
	kVK_Tab=0x30, kVK_Space=0x31, kVK_Grave=0x32, kVK_Delete=0x33, kVK_Escape=0x35,
	kVK_Command=0x37, kVK_Shift=0x38, kVK_CapsLock=0x39, kVK_Option=0x3A,
	kVK_Control=0x3B, kVK_RightShift=0x3C, kVK_RightOption=0x3D, kVK_RightControl=0x3E,
	kVK_F1=0x7A, kVK_F2=0x78, kVK_F3=0x63, kVK_F4=0x76, kVK_F5=0x60, kVK_F6=0x61,
	kVK_F7=0x62, kVK_F8=0x64, kVK_F9=0x65, kVK_F10=0x6D, kVK_F11=0x67, kVK_F12=0x6F,
	kVK_LeftArrow=0x7B, kVK_RightArrow=0x7C, kVK_DownArrow=0x7D, kVK_UpArrow=0x7E,
	kVK_ForwardDelete=0x75, kVK_Home=0x73, kVK_End=0x77, kVK_PageUp=0x74, kVK_PageDown=0x79,
	kVK_KP0=0x52, kVK_KP1=0x53, kVK_KP2=0x54, kVK_KP3=0x55, kVK_KP4=0x56,
	kVK_KP5=0x57, kVK_KP6=0x58, kVK_KP7=0x59, kVK_KP8=0x5B, kVK_KP9=0x5C,
	kVK_KPEnter=0x4C, kVK_KPPlus=0x45, kVK_KPMinus=0x4E, kVK_KPMultiply=0x43,
	kVK_KPDivide=0x4B, kVK_KPDecimal=0x41,
};

UnsignedByte MapMacKey(int kc)
{
	switch (kc) {
		case kVK_A: return KEY_A; case kVK_B: return KEY_B; case kVK_C: return KEY_C;
		case kVK_D: return KEY_D; case kVK_E: return KEY_E; case kVK_F: return KEY_F;
		case kVK_G: return KEY_G; case kVK_H: return KEY_H; case kVK_I: return KEY_I;
		case kVK_J: return KEY_J; case kVK_K: return KEY_K; case kVK_L: return KEY_L;
		case kVK_M: return KEY_M; case kVK_N: return KEY_N; case kVK_O: return KEY_O;
		case kVK_P: return KEY_P; case kVK_Q: return KEY_Q; case kVK_R: return KEY_R;
		case kVK_S: return KEY_S; case kVK_T: return KEY_T; case kVK_U: return KEY_U;
		case kVK_V: return KEY_V; case kVK_W: return KEY_W; case kVK_X: return KEY_X;
		case kVK_Y: return KEY_Y; case kVK_Z: return KEY_Z;
		case kVK_0: return KEY_0; case kVK_1: return KEY_1; case kVK_2: return KEY_2;
		case kVK_3: return KEY_3; case kVK_4: return KEY_4; case kVK_5: return KEY_5;
		case kVK_6: return KEY_6; case kVK_7: return KEY_7; case kVK_8: return KEY_8;
		case kVK_9: return KEY_9;
		case kVK_Escape:    return KEY_ESC;
		case kVK_Return:    return KEY_ENTER;
		case kVK_Space:     return KEY_SPACE;
		case kVK_Tab:       return KEY_TAB;
		case kVK_Delete:    return KEY_BACKSPACE;
		case kVK_ForwardDelete: return KEY_DEL;
		case kVK_Minus:     return KEY_MINUS;
		case kVK_Equal:     return KEY_EQUAL;
		case kVK_LeftBracket:  return KEY_LBRACKET;
		case kVK_RightBracket: return KEY_RBRACKET;
		case kVK_Semicolon: return KEY_SEMICOLON;
		case kVK_Quote:     return KEY_APOSTROPHE;
		case kVK_Grave:     return KEY_TICK;
		case kVK_Backslash: return KEY_BACKSLASH;
		case kVK_Comma:     return KEY_COMMA;
		case kVK_Period:    return KEY_PERIOD;
		case kVK_Slash:     return KEY_SLASH;
		case kVK_CapsLock:  return KEY_CAPS;
		case kVK_Shift:     return KEY_LSHIFT;
		case kVK_RightShift:return KEY_RSHIFT;
		case kVK_Control:   return KEY_LCTRL;
		case kVK_RightControl: return KEY_RCTRL;
		case kVK_Option:    return KEY_LALT;
		case kVK_RightOption: return KEY_RALT;
		case kVK_Command:   return KEY_LCTRL;  // best-effort: macOS Cmd -> Ctrl
		case kVK_UpArrow:   return KEY_UP;
		case kVK_DownArrow: return KEY_DOWN;
		case kVK_LeftArrow: return KEY_LEFT;
		case kVK_RightArrow:return KEY_RIGHT;
		case kVK_Home:      return KEY_HOME;
		case kVK_End:       return KEY_END;
		case kVK_PageUp:    return KEY_PGUP;
		case kVK_PageDown:  return KEY_PGDN;
		case kVK_F1: return KEY_F1; case kVK_F2: return KEY_F2; case kVK_F3: return KEY_F3;
		case kVK_F4: return KEY_F4; case kVK_F5: return KEY_F5; case kVK_F6: return KEY_F6;
		case kVK_F7: return KEY_F7; case kVK_F8: return KEY_F8; case kVK_F9: return KEY_F9;
		case kVK_F10: return KEY_F10; case kVK_F11: return KEY_F11; case kVK_F12: return KEY_F12;
		case kVK_KP0: return KEY_KP0; case kVK_KP1: return KEY_KP1; case kVK_KP2: return KEY_KP2;
		case kVK_KP3: return KEY_KP3; case kVK_KP4: return KEY_KP4; case kVK_KP5: return KEY_KP5;
		case kVK_KP6: return KEY_KP6; case kVK_KP7: return KEY_KP7; case kVK_KP8: return KEY_KP8;
		case kVK_KP9: return KEY_KP9;
		case kVK_KPEnter:    return KEY_KPENTER;
		case kVK_KPPlus:     return KEY_KPPLUS;
		case kVK_KPMinus:    return KEY_KPMINUS;
		case kVK_KPMultiply: return KEY_KPSTAR;
		case kVK_KPDivide:   return KEY_KPSLASH;
		case kVK_KPDecimal:  return KEY_KPDEL;
		default:            return KEY_NONE;
	}
}
} // namespace

CocoaKeyboard::CocoaKeyboard() {}
CocoaKeyboard::~CocoaKeyboard() {}

void CocoaKeyboard::init()   { Keyboard::init(); }
void CocoaKeyboard::reset()  { Keyboard::reset(); }

void CocoaKeyboard::update()
{
	Keyboard::update();

	// TheSuperHackers @port macOS text-input bridge. The Cocoa/Metal main loop
	// has no Win32 WndProc, so the WM_CHAR -> IMEManager::serviceIMEMessage ->
	// GWM_IME_CHAR path that feeds printable characters to text-entry gadgets on
	// Windows never runs — leaving every in-game text field (player name, LAN
	// game name, chat, ...) unable to accept typed input. Rebuild it here: drain
	// the characters NSEvent already composed for us (correct for the live system
	// keyboard layout, shift/caps/dead-keys) and deliver each to the focused GUI
	// window as GWM_IME_CHAR — exactly the message GadgetTextEntryInput consumes
	// to append a character (and to finish editing on Return).
	if( TheWindowManager )
	{
		GameWindow *focus = TheWindowManager->winGetFocus();
		unsigned int ch;
		while( MetalInput_PollChar( &ch ) )   // drain fully even with no focus
		{
			if( focus )
				TheWindowManager->winSendInputMsg( focus, GWM_IME_CHAR,
																					 (WindowMsgData)ch, 0 );
		}
	}
}

Bool CocoaKeyboard::getCapsState() { return MetalInput_CapsOn() ? TRUE : FALSE; }

void CocoaKeyboard::getKey( KeyboardIO *key )
{
	key->key = KEY_NONE;

	int kc, down;
	while (MetalInput_PollKey(&kc, &down)) {
		UnsignedByte k = MapMacKey(kc);
		if (k == KEY_NONE) continue;   // skip unmapped, keep draining the queue
		key->key    = k;
		key->state  = down ? KEY_STATE_DOWN : KEY_STATE_UP;
		key->status = KeyboardIO::STATUS_UNUSED;
		if (down) key->keyDownTimeMsec = timeGetTime();
		return;
	}
}

#endif // __APPLE__
