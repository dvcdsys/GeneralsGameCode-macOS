#pragma once
// <snmp.h> shim for non-Windows builds.
//
// The GameSpy connection-tracking code uses the Windows SNMP MIB-II extension
// (loaded dynamically via GetProcAddress) to enumerate active TCP connections
// for NAT detection. On macOS the DLLs never load (GetProcAddress returns NULL),
// so the feature is inert, but the SNMP *types* below are needed for the code
// to compile.
// TODO(macos): replace with a sysctl/PF_ROUTE-based connection enumerator if NAT
// negotiation is ever needed on macOS.
#ifndef _WIN32

#include "windows.h"

typedef long          AsnInteger;
typedef long          AsnInteger32;
typedef unsigned long AsnCounter;
typedef unsigned long AsnGauge;
typedef unsigned long AsnTimeticks;
typedef unsigned int  UINT_SNMP;

// Object identifier: a sequence of sub-identifiers.
typedef struct {
  UINT          idLength;
  unsigned int *ids;
} AsnObjectIdentifier;

typedef struct {
  unsigned int  length;
  unsigned char *stream;
  BOOL          dynamic;
} AsnOctetString;

// Variant SNMP value.
typedef struct {
  BYTE asnType;
  union {
    AsnInteger          number;
    AsnOctetString      string;
    AsnObjectIdentifier object;
    AsnOctetString      address;
    AsnCounter          counter;
    AsnGauge            gauge;
    AsnTimeticks        ticks;
  } asnValue;
} AsnAny;

typedef struct {
  AsnObjectIdentifier name;
  AsnAny              value;
} RFC1157VarBind, SnmpVarBind;

typedef struct {
  RFC1157VarBind *list;
  UINT            len;
} RFC1157VarBindList, SnmpVarBindList;

typedef DWORD SNMPAPI;

// PDU type codes (only GETNEXTREQUEST is referenced, and that path is dead).
#ifndef ASN_RFC1157_GETNEXTREQUEST
#define ASN_RFC1157_GETNEXTREQUEST 0xA1
#define ASN_RFC1157_GETREQUEST     0xA0
#define ASN_RFC1155_IPADDRESS      0x40
#define ASN_INTEGER                0x02
#define ASN_OCTETSTRING            0x04
#endif

// SNMP PDU type constants used by the NIC enumeration code.
#ifndef SNMP_PDU_GETNEXT
#define SNMP_PDU_GET      0xA0
#define SNMP_PDU_GETNEXT  0xA1
#define SNMP_PDU_RESPONSE 0xA2
#define SNMP_PDU_SET      0xA3
#endif

#endif // !_WIN32
