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

// FILE: W3DGameEngine.cpp ////////////////////////////////////////////////////////////////////////
// Author: Colin Day, April 2001
// Description:
//   Implementation of the Win32 game engine, this is the highest level of
//   the game application, it creates all the devices we will use for the game
///////////////////////////////////////////////////////////////////////////////////////////////////

#include <windows.h>

#include "Win32Device/Common/Win32GameEngine.h"
#include "Common/PerfTimer.h"

#include "GameNetwork/LANAPICallbacks.h"

extern DWORD TheMessageTime;

//-------------------------------------------------------------------------------------------------
/** Constructor for Win32GameEngine */
//-------------------------------------------------------------------------------------------------
Win32GameEngine::Win32GameEngine()
{
	// Stop blue screen
	m_previousErrorMode = SetErrorMode( SEM_FAILCRITICALERRORS );
}

//-------------------------------------------------------------------------------------------------
/** Destructor for Win32GameEngine */
//-------------------------------------------------------------------------------------------------
Win32GameEngine::~Win32GameEngine()
{
	// restore it (this isn't really necessary, but feels good.)
	SetErrorMode( m_previousErrorMode );
}


//-------------------------------------------------------------------------------------------------
/** Initialize the game engine */
//-------------------------------------------------------------------------------------------------
void Win32GameEngine::init()
{

	// extending functionality
	GameEngine::init();

}

//-------------------------------------------------------------------------------------------------
/** Reset the system */
//-------------------------------------------------------------------------------------------------
void Win32GameEngine::reset()
{

	// extending functionality
	GameEngine::reset();

}

//-------------------------------------------------------------------------------------------------
/** Update the game engine by updating the GameClient and
	* GameLogic singletons. */
//-------------------------------------------------------------------------------------------------
void Win32GameEngine::update()
{


	// call the engine normal update
	GameEngine::update();

	extern HWND ApplicationHWnd;
	if (ApplicationHWnd && ::IsIconic(ApplicationHWnd)) {
		while (ApplicationHWnd && ::IsIconic(ApplicationHWnd)) {
			// We are alt-tabbed out here.  Sleep a bit, & process windows
			// so that we can become un-alt-tabbed out.
			Sleep(5);
			serviceWindowsOS();

			if (TheLAN != nullptr) {
				// BGC - need to update TheLAN so we can process and respond to other
				// people's messages who may not be alt-tabbed out like we are.
				TheLAN->setIsActive(isActive());
				TheLAN->update();
			}

			// If we are running a multiplayer game, keep running the logic.
			// There is code in the client to skip client redraw if we are
			// iconic.  jba.
			if (TheGameEngine->getQuitting() || TheGameLogic->isInInternetGame() || TheGameLogic->isInLanGame()) {
				break; // keep running.
			}
		}

    // When we are alt-tabbed out... the MilesAudioManager seems to go into a coma sometimes
    // and not regain focus properly when we come back. This seems to wake it up nicely.
    AudioAffect aa = (AudioAffect)0x10;
		TheAudio->setVolume(TheAudio->getVolume( aa ), aa );

	}

	// allow windows to perform regular windows maintenance stuff like msgs
	serviceWindowsOS();

}

//-------------------------------------------------------------------------------------------------
/** This function may be called from within this application to let
  * Microsoft Windows do its message processing and dispatching.  Presumably
	* we would call this at least once each time around the game loop to keep
	* Windows services from backing up */
//-------------------------------------------------------------------------------------------------
#if defined(__APPLE__)
// TheSuperHackers @port On macOS there is no Win32 WndProc; the Cocoa window
// (Metal backend) captures NSEvents into a global queue. Drain the mouse queue
// here each frame and synthesize the same Win32 messages the Win32Mouse event
// translator already understands, so all of Win32Mouse/W3DMouse (incl. the
// in-game cursor drawing) works unchanged.
extern "C" int MetalInput_PollMouse(int* type, int* x, int* y, int* delta);
#include "Win32Device/GameClient/Win32Mouse.h"
extern Win32Mouse *TheWin32Mouse;
// Mirror of MetalMouseEventType in cmake/dx8_stub/metal_backend.h (not on the
// include path here). Keep in sync.
enum {
	METAL_MOUSE_MOVE = 1, METAL_MOUSE_LDOWN = 2, METAL_MOUSE_LUP = 3, METAL_MOUSE_LDBL = 4,
	METAL_MOUSE_RDOWN = 5, METAL_MOUSE_RUP = 6, METAL_MOUSE_MDOWN = 7, METAL_MOUSE_MUP = 8,
	METAL_MOUSE_WHEEL = 9,
};
static void Apple_PumpMouseInput()
{
	if (!TheWin32Mouse) return;
	int type, x, y, delta;
	while (MetalInput_PollMouse(&type, &x, &y, &delta)) {
		UINT   msg    = 0;
		WPARAM wParam = 0;
		LPARAM lParam = (LPARAM)(((y & 0xFFFF) << 16) | (x & 0xFFFF));
		switch (type) {
			case METAL_MOUSE_MOVE:  msg = WM_MOUSEMOVE;     break;
			case METAL_MOUSE_LDOWN: msg = WM_LBUTTONDOWN;   break;
			case METAL_MOUSE_LUP:   msg = WM_LBUTTONUP;     break;
			case METAL_MOUSE_LDBL:  msg = WM_LBUTTONDBLCLK; break;
			case METAL_MOUSE_RDOWN: msg = WM_RBUTTONDOWN;   break;
			case METAL_MOUSE_RUP:   msg = WM_RBUTTONUP;     break;
			case METAL_MOUSE_MDOWN: msg = WM_MBUTTONDOWN;   break;
			case METAL_MOUSE_MUP:   msg = WM_MBUTTONUP;     break;
			case METAL_MOUSE_WHEEL: msg = WM_MOUSEWHEEL;
			                        wParam = (WPARAM)(((delta & 0xFFFF) << 16)); break;
			default: continue;
		}
		TheWin32Mouse->addWin32Event(msg, wParam, lParam, 0);
	}
}
#endif

void Win32GameEngine::serviceWindowsOS()
{
#if defined(__APPLE__)
	Apple_PumpMouseInput();
#endif
	MSG msg;
  Int returnValue;

	//
	// see if we have any messages to process, a nullptr window handle tells the
	// OS to look at the main window associated with the calling thread, us!
	//
	while( PeekMessage( &msg, nullptr, 0, 0, PM_NOREMOVE ) )
	{

		// get the message
		returnValue = GetMessage( &msg, nullptr, 0, 0 );

		// this is one possible way to check for quitting conditions as a message
		// of WM_QUIT will cause GetMessage() to return 0
/*
		if( returnValue == 0 )
		{

			setQuitting( true );
			break;

		}
*/

		TheMessageTime = msg.time;
		// translate and dispatch the message
		TranslateMessage( &msg );
		DispatchMessage( &msg );
		TheMessageTime = 0;

	}

}

