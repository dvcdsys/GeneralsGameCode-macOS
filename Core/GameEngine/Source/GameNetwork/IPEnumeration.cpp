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

#include "PreRTS.h"	// This must go first in EVERY cpp file in the GameEngine

#include "GameNetwork/IPEnumeration.h"
#include "GameNetwork/networkutil.h"
#include "GameClient/ClientInstance.h"

#if defined(__APPLE__)
// TheSuperHackers @port macOS: native IPv4 interface enumeration (see getAddresses).
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#endif

IPEnumeration::IPEnumeration()
{
	m_IPlist = nullptr;
	m_isWinsockInitialized = false;
}

IPEnumeration::~IPEnumeration()
{
	if (m_isWinsockInitialized)
	{
		WSACleanup();
		m_isWinsockInitialized = false;
	}

	EnumeratedIP *ip = m_IPlist;
	while (ip)
	{
		ip = ip->getNext();
		deleteInstance(m_IPlist);
		m_IPlist = ip;
	}
}

EnumeratedIP * IPEnumeration::getAddresses()
{
	if (m_IPlist)
		return m_IPlist;

#if defined(__APPLE__)
	// TheSuperHackers @port macOS: enumerate local IPv4 interfaces with getifaddrs()
	// instead of gethostbyname(hostname). On macOS the machine's ".local" hostname
	// usually does NOT resolve to its LAN address, so gethostbyname returned null and
	// left m_IPlist empty — then LanLobbyMenuInit did `IP = IPlist->getIP()` on that
	// null pointer and hard-crashed (EXC_BAD_ACCESS at 0x10) the moment you opened the
	// LAN lobby. getifaddrs() is the canonical POSIX enumeration and needs no name
	// resolution. Networking plumbing only — no game logic, Windows path untouched.

	// Preserve the Windows multi-instance loopback-ID feature (unique 127.x per client).
	if (rts::ClientInstance::isMultiInstance())
	{
		const UnsignedInt id = rts::ClientInstance::getInstanceId();
		addNewIP(
			127,
			(UnsignedByte)(id >> 16),
			(UnsignedByte)(id >> 8),
			(UnsignedByte)(id));
	}

	struct ifaddrs *ifaddr = nullptr;
	if (getifaddrs(&ifaddr) == 0)
	{
		for (struct ifaddrs *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next)
		{
			if (ifa->ifa_addr == nullptr)
				continue;
			if (ifa->ifa_addr->sa_family != AF_INET)
				continue;                              // IPv4 only (engine uses 4-byte IPs)
			if ((ifa->ifa_flags & IFF_UP) == 0)
				continue;                              // skip interfaces that are down
			if (ifa->ifa_flags & IFF_LOOPBACK)
				continue;                              // skip 127.0.0.1

			// s_addr is in network byte order; its 4 octets are already in dotted order,
			// matching how the Windows path feeds h_addr_list bytes to addNewIP.
			const struct sockaddr_in *sa = (const struct sockaddr_in *)ifa->ifa_addr;
			const UnsignedByte *b = (const UnsignedByte *)&sa->sin_addr.s_addr;
			addNewIP(b[0], b[1], b[2], b[3]);
		}
		freeifaddrs(ifaddr);
	}

	// Fallback: no usable interface (Wi-Fi off / no Ethernet) — add loopback so the LAN
	// lobby still OPENS instead of crashing; the user just won't see other LAN games.
	if (!m_IPlist)
		addNewIP(127, 0, 0, 1);

	return m_IPlist;
#else
	if (!m_isWinsockInitialized)
	{
		WORD verReq = MAKEWORD(2, 2);
		WSADATA wsadata;

		int err = WSAStartup(verReq, &wsadata);
		if (err != 0) {
			return nullptr;
		}

		if ((LOBYTE(wsadata.wVersion) != 2) || (HIBYTE(wsadata.wVersion) !=2)) {
			WSACleanup();
			return nullptr;
		}
		m_isWinsockInitialized = true;
	}

	// get the local machine's host name
	char hostname[256];
	if (gethostname(hostname, sizeof(hostname)))
	{
		DEBUG_LOG(("Failed call to gethostname; WSAGetLastError returned %d", WSAGetLastError()));
		return nullptr;
	}
	DEBUG_LOG(("Hostname is '%s'", hostname));

	// get host information from the host name
	HOSTENT* hostEnt = gethostbyname(hostname);
	if (hostEnt == nullptr)
	{
		DEBUG_LOG(("Failed call to gethostbyname; WSAGetLastError returned %d", WSAGetLastError()));
		return nullptr;
	}

	// sanity-check the length of the IP adress
	if (hostEnt->h_length != 4)
	{
		DEBUG_LOG(("gethostbyname returns oddly-sized IP addresses!"));
		return nullptr;
	}

	// TheSuperHackers @feature Add one unique local host IP address for each multi client instance.
	if (rts::ClientInstance::isMultiInstance())
	{
		const UnsignedInt id = rts::ClientInstance::getInstanceId();
		addNewIP(
			127,
			(UnsignedByte)(id >> 16),
			(UnsignedByte)(id >> 8),
			(UnsignedByte)(id));
	}

	// construct a list of addresses
	int numAddresses = 0;
	char *entry;
	while ( (entry = hostEnt->h_addr_list[numAddresses++]) != nullptr )
	{
		addNewIP(
			(UnsignedByte)entry[0],
			(UnsignedByte)entry[1],
			(UnsignedByte)entry[2],
			(UnsignedByte)entry[3]);
	}

	return m_IPlist;
#endif // __APPLE__
}

void IPEnumeration::addNewIP( UnsignedByte a, UnsignedByte b, UnsignedByte c, UnsignedByte d )
{
	EnumeratedIP *newIP = newInstance(EnumeratedIP);

	AsciiString str;
	str.format("%d.%d.%d.%d", (int)a, (int)b, (int)c, (int)d);

	UnsignedInt ip = AssembleIp(a, b, c, d);

	newIP->setIPstring(str);
	newIP->setIP(ip);

	DEBUG_LOG(("IP: 0x%8.8X (%s)", ip, str.str()));

	// Add the IP to the list in ascending order
	if (!m_IPlist)
	{
		m_IPlist = newIP;
		newIP->setNext(nullptr);
	}
	else
	{
		if (newIP->getIP() < m_IPlist->getIP())
		{
			newIP->setNext(m_IPlist);
			m_IPlist = newIP;
		}
		else
		{
			EnumeratedIP *p = m_IPlist;
			while (p->getNext() && p->getNext()->getIP() < newIP->getIP())
			{
				p = p->getNext();
			}
			newIP->setNext(p->getNext());
			p->setNext(newIP);
		}
	}
}

AsciiString IPEnumeration::getMachineName()
{
	if (!m_isWinsockInitialized)
	{
		WORD verReq = MAKEWORD(2, 2);
		WSADATA wsadata;

		int err = WSAStartup(verReq, &wsadata);
		if (err != 0) {
			return "";
		}

		if ((LOBYTE(wsadata.wVersion) != 2) || (HIBYTE(wsadata.wVersion) !=2)) {
			WSACleanup();
			return "";
		}
		m_isWinsockInitialized = true;
	}

	// get the local machine's host name
	char hostname[256];
	if (gethostname(hostname, sizeof(hostname)))
	{
		DEBUG_LOG(("Failed call to gethostname; WSAGetLastError returned %d", WSAGetLastError()));
		return "";
	}

	return AsciiString(hostname);
}


