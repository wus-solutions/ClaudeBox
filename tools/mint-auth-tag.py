#!/usr/bin/env python3
"""Signiert eine NIP-OA-Attestierung fuer einen Agenten.

Aufruf: mint-auth-tag.py <owner-privkey> <agent-pubkey>
        mint-auth-tag.py --pubkey <privkey>    # welcher Schluessel ist das?
        mint-auth-tag.py --selftest

Schluessel gehen als Hex oder als bech32 (nsec/npub). Buzz Desktop gibt den
eigenen Schluessel unter Settings -> Private key -> Reveal als nsec heraus.

Ohne diese Attestierung ist ein Agent fuer Buzz ein gewoehnliches Konto: er
steht nicht im Agentenverzeichnis, taucht in keiner Agentenliste auf, und eine
@-Mention zieht ihn nicht in einen Huddle. Das Verzeichnis liest die
Attestierung aus dem kind:0-Profil des Agenten, und dort landet sie nur, wenn
das CLI sie als BUZZ_AUTH_TAG an jedes Event haengt.

Signiert wird nach docs/nips/NIP-OA.md aus dem Buzz-Repo:

    Nachricht = SHA256("nostr:agent-auth:" + <agent-pubkey> + ":" + <conditions>)
    Tag       = ["auth", <owner-pubkey>, <conditions>, <signatur>]

Dieses Skript laesst die Conditions leer - so wie das offizielle Beispiel
(crates/buzz-sdk/examples/compute_auth_tag.rs) und wie der Entrypoint das Tag
im Container zusammensetzt. Eine Attestierung mit Bedingungen (kind=,
created_at<) passt nicht zu BUZZ_AUTH_TAGS und muss von Hand gesetzt werden.

Ausgegeben wird auf stdout nur die Signatur - das ist der Wert fuer
BUZZ_AUTH_TAGS=<agent>=<signatur>. Alles Erklaerende geht nach stderr, damit
die Ausgabe in eine Variable gepipet werden kann.

Der private Schluessel des Owners verlaesst diesen Rechner nicht: das Skript
laeuft auf dem Host, nie im Container, und braucht kein Netz. Die Signatur
selbst ist kein Geheimnis - sie haengt anschliessend an jedem Event des
Agenten.

Reines Python ab 3.9 (das System-Python von macOS reicht), keine
Abhaengigkeiten, kein Docker, kein Netz. --selftest prueft das Signieren gegen
die offiziellen BIP-340-Testvektoren; jede erzeugte Signatur wird ausserdem vor
der Ausgabe selbst verifiziert.
"""
import hashlib
import sys
from typing import List, Optional, Tuple

if sys.version_info < (3, 9):
    raise SystemExit("Dieses Skript braucht Python 3.9 oder neuer.")

# secp256k1
P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)

# Ein Punkt der Kurve, oder None fuer den Punkt im Unendlichen. Bewusst als
# Optional[...] und nicht als "tuple[...] | None": das kurze | fuer Typen gibt
# es erst ab Python 3.10, und macOS liefert 3.9 mit. Das Skript laeuft auf dem
# Host, also mit dem Python, das dort eben steht.
Point = Optional[Tuple[int, int]]


def point_add(p1: Point, p2: Point) -> Point:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    if p1[0] == p2[0] and p1[1] != p2[1]:
        return None
    if p1 == p2:
        lam = 3 * p1[0] * p1[0] * pow(2 * p1[1], P - 2, P) % P
    else:
        lam = (p2[1] - p1[1]) * pow(p2[0] - p1[0], P - 2, P) % P
    x = (lam * lam - p1[0] - p2[0]) % P
    return (x, (lam * (p1[0] - x) - p1[1]) % P)


def point_mul(point: Point, scalar: int) -> Point:
    result: Point = None
    for i in range(256):
        if (scalar >> i) & 1:
            result = point_add(result, point)
        point = point_add(point, point)
    return result


def lift_x(x: int) -> Point:
    """Der Punkt mit dieser x-Koordinate und gerader y-Koordinate (BIP-340)."""
    if x >= P:
        return None
    y_sq = (pow(x, 3, P) + 7) % P
    y = pow(y_sq, (P + 1) // 4, P)
    if pow(y, 2, P) != y_sq:
        return None
    return (x, y if y % 2 == 0 else P - y)


def tagged_hash(tag: str, msg: bytes) -> bytes:
    prefix = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(prefix + prefix + msg).digest()


def x_bytes(point: Point) -> bytes:
    assert point is not None
    return point[0].to_bytes(32, "big")


def schnorr_sign(msg: bytes, seckey: int, aux: bytes) -> bytes:
    """BIP-340-Signatur. `aux` ist die 32-Byte-Zufallsbeigabe der Spezifikation."""
    if not 1 <= seckey <= N - 1:
        raise ValueError("privater Schluessel liegt ausserhalb von [1, n-1]")
    pubpoint = point_mul(G, seckey)
    assert pubpoint is not None
    d = seckey if pubpoint[1] % 2 == 0 else N - seckey
    t = d ^ int.from_bytes(tagged_hash("BIP0340/aux", aux), "big")
    rand = tagged_hash("BIP0340/nonce", t.to_bytes(32, "big") + x_bytes(pubpoint) + msg)
    k0 = int.from_bytes(rand, "big") % N
    if k0 == 0:
        raise ValueError("Nonce wurde 0 - mit anderer Zufallsbeigabe erneut versuchen")
    rpoint = point_mul(G, k0)
    assert rpoint is not None
    k = k0 if rpoint[1] % 2 == 0 else N - k0
    e = (
        int.from_bytes(
            tagged_hash("BIP0340/challenge", x_bytes(rpoint) + x_bytes(pubpoint) + msg),
            "big",
        )
        % N
    )
    return x_bytes(rpoint) + ((k + e * d) % N).to_bytes(32, "big")


def schnorr_verify(msg: bytes, pubkey: bytes, sig: bytes) -> bool:
    """Prueft nach der Formel der Spezifikation: R = s*G - e*P."""
    if len(pubkey) != 32 or len(sig) != 64:
        return False
    point = lift_x(int.from_bytes(pubkey, "big"))
    if point is None:
        return False
    r = int.from_bytes(sig[:32], "big")
    s = int.from_bytes(sig[32:], "big")
    if r >= P or s >= N:
        return False
    e = int.from_bytes(tagged_hash("BIP0340/challenge", sig[:32] + pubkey + msg), "big") % N
    rpoint = point_add(point_mul(G, s), point_mul(point, N - e))
    return rpoint is not None and rpoint[1] % 2 == 0 and rpoint[0] == r


def pubkey_of(seckey: int) -> bytes:
    return x_bytes(point_mul(G, seckey))


def auth_message(agent_pubkey: str, conditions: str = "") -> bytes:
    preimage = f"nostr:agent-auth:{agent_pubkey}:{conditions}"
    return hashlib.sha256(preimage.encode()).digest()


BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_GENERATOR = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]


def bech32_polymod(values: List[int]) -> int:
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for i in range(5):
            if (top >> i) & 1:
                chk ^= BECH32_GENERATOR[i]
    return chk


def bech32_hrp_expand(hrp: str) -> List[int]:
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def convertbits(data: List[int], frombits: int, tobits: int) -> bytes:
    """5-Bit-Gruppen zu Bytes, ohne Polsterung - so codiert NIP-19 Schluessel."""
    acc = 0
    bits = 0
    out = bytearray()
    maxv = (1 << tobits) - 1
    for value in data:
        if value < 0 or value >> frombits:
            raise ValueError("Wert passt nicht in die Gruppenbreite")
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            out.append((acc >> bits) & maxv)
    if bits >= frombits or ((acc << (tobits - bits)) & maxv):
        raise ValueError("ungueltige Polsterung")
    return bytes(out)


def bech32_decode(text: str) -> Tuple[str, bytes]:
    """Gibt (hrp, Nutzdaten) zurueck. Wirft ValueError bei kaputter Pruefsumme.

    Die Pruefsumme ist der Grund, das selbst zu machen: ein verrutschtes
    Zeichen im nsec faellt hier auf und nicht erst als ungueltige Signatur, die
    dann an jedem Event des Agenten haengt.
    """
    if text != text.lower() and text != text.upper():
        raise ValueError("gemischte Gross-/Kleinschreibung")
    text = text.lower()
    if len(text) > 90:
        raise ValueError("zu lang fuer bech32")
    pos = text.rfind("1")
    if pos < 1 or pos + 7 > len(text):
        raise ValueError("kein Trennzeichen gefunden")
    hrp = text[:pos]
    data = []
    for char in text[pos + 1 :]:
        if char not in BECH32_CHARSET:
            raise ValueError(f"Zeichen {char!r} gehoert nicht zum bech32-Alphabet")
        data.append(BECH32_CHARSET.index(char))
    if bech32_polymod(bech32_hrp_expand(hrp) + data) != 1:
        raise ValueError("Pruefsumme stimmt nicht - vertippt oder abgeschnitten?")
    return hrp, convertbits(data[:-6], 5, 8)


def parse_key(label: str, value: str, bech32_hrp: str) -> str:
    """Nimmt Hex oder bech32 (nsec/npub) und gibt 64 Hex-Zeichen zurueck."""
    text = value.strip()
    if text.lower().startswith(("nsec1", "npub1")):
        try:
            hrp, raw = bech32_decode(text)
        except ValueError as error:
            raise SystemExit(f"FEHLER: {label} ist kein gueltiges bech32: {error}")
        if hrp != bech32_hrp:
            raise SystemExit(
                f"FEHLER: {label} ist ein '{hrp}', erwartet wird '{bech32_hrp}'. "
                "Owner-Privkey ist ein nsec, Agent-Pubkey ein npub."
            )
        if len(raw) != 32:
            raise SystemExit(f"FEHLER: {label} enthaelt {len(raw)} statt 32 Byte.")
        return raw.hex()
    return parse_hex(label, text, 64)


def parse_hex(label: str, value: str, nibbles: int) -> str:
    text = value.strip().lower()
    if len(text) != nibbles or any(c not in "0123456789abcdef" for c in text):
        raise SystemExit(f"FEHLER: {label} muss {nibbles} Hex-Zeichen sein (ist: {len(text)}).")
    return text


# Offizielle BIP-340-Testvektoren (bitcoin/bips, bip-0340/test-vectors.csv),
# die Zeilen mit privatem Schluessel. Mit fester Zufallsbeigabe ist die
# Signatur deterministisch und vergleichbar.
BIP340_VECTORS = [
    (
        "0000000000000000000000000000000000000000000000000000000000000003",
        "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0",
    ),
    (
        "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef",
        "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659",
        "0000000000000000000000000000000000000000000000000000000000000001",
        "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
        "6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a",
    ),
    (
        "c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9",
        "dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8",
        "c87aa53824b4d7ae2eb035a2b5bbbccc080e76cdc6d1692c4b0b62d798e6d906",
        "7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c",
        "5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1bab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7",
    ),
    (
        "0b432b2677937381aef05bb02a66ecd012773062cf3fa2549e44f58ed2401710",
        "25d1dff95105f5253c4022f628a996ad3a0d95fbf21d468a1b33f8c160d8f517",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "7eb0509757e246f19449885651611cb965ecc1a187dd51b64fda1edc9637d5ec97582b9cb13db3933705b32ba982af5af25fd78881ebb32771fc5922efc66ea3",
    ),
]


# Das Pubkey-Beispiel aus NIP-19. Deckt bech32-Alphabet, Pruefsumme und
# 5-zu-8-Bit-Umrechnung in einem ab - und damit denselben Codeweg, den ein
# nsec nimmt. Bewusst ein npub und kein nsec: ein nsec-Literal im Repo sieht
# fuer den pre-commit-Hook wie ein echtes Geheimnis aus, und das zu Recht.
NIP19_NPUB = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
NIP19_HEX = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"


def selftest_bech32() -> int:
    failures = 0
    got = parse_key("npub", NIP19_NPUB, "npub")
    if got == NIP19_HEX:
        print("  NIP-19-npub: ok", file=sys.stderr)
    else:
        print(f"FEHLER npub: {got} statt {NIP19_HEX}", file=sys.stderr)
        failures += 1

    # Ein verrutschtes Zeichen muss an der Pruefsumme scheitern, nicht still
    # einen falschen Schluessel ergeben.
    broken = NIP19_NPUB[:-1] + ("4" if NIP19_NPUB[-1] != "4" else "5")
    try:
        parse_key("npub", broken, "npub")
        print("FEHLER: npub mit kaputter Pruefsumme wurde angenommen", file=sys.stderr)
        failures += 1
    except SystemExit:
        print("  kaputte Pruefsumme: abgewiesen", file=sys.stderr)

    # Vertauschte Schluessel sind der wahrscheinlichste Bedienfehler.
    try:
        parse_key("Owner-Privkey", NIP19_NPUB, "nsec")
        print("FEHLER: npub wurde als Privkey angenommen", file=sys.stderr)
        failures += 1
    except SystemExit:
        print("  npub als Privkey: abgewiesen", file=sys.stderr)
    return failures


def selftest() -> int:
    failures = selftest_bech32()
    for index, (sec, pub, aux, msg, expected) in enumerate(BIP340_VECTORS):
        seckey = int(sec, 16)
        got_pub = pubkey_of(seckey).hex()
        if got_pub != pub:
            print(f"FEHLER Vektor {index}: Pubkey {got_pub} statt {pub}", file=sys.stderr)
            failures += 1
            continue
        sig = schnorr_sign(bytes.fromhex(msg), seckey, bytes.fromhex(aux))
        if sig.hex() != expected:
            print(f"FEHLER Vektor {index}: Signatur {sig.hex()} statt {expected}", file=sys.stderr)
            failures += 1
            continue
        if not schnorr_verify(bytes.fromhex(msg), bytes.fromhex(pub), sig):
            print(f"FEHLER Vektor {index}: eigene Signatur verifiziert nicht", file=sys.stderr)
            failures += 1
            continue
        broken = bytes.fromhex(msg[:-2] + ("00" if msg[-2:] != "00" else "01"))
        if schnorr_verify(broken, bytes.fromhex(pub), sig):
            print(f"FEHLER Vektor {index}: fremde Nachricht verifiziert", file=sys.stderr)
            failures += 1
            continue
        print(f"  Vektor {index}: ok", file=sys.stderr)

    if failures:
        print(f"{failures} Pruefung(en) fehlgeschlagen.", file=sys.stderr)
        return 1
    print(
        f"Alle {len(BIP340_VECTORS)} BIP-340-Vektoren und die bech32-Pruefungen bestanden.",
        file=sys.stderr,
    )
    return 0


def main(argv: List[str]) -> int:
    if len(argv) == 1 and argv[0] == "--selftest":
        return selftest()
    if len(argv) == 2 and argv[0] == "--pubkey":
        # Zum Auseinanderhalten der Schluessel, ohne Relay und ohne Netz.
        seckey = int(parse_key("Privkey", argv[1], "nsec"), 16)
        if not 1 <= seckey <= N - 1:
            raise SystemExit("FEHLER: Privkey liegt ausserhalb von [1, n-1].")
        print(pubkey_of(seckey).hex())
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 1

    owner_priv = parse_key("Owner-Privkey", argv[0], "nsec")
    agent_pub = parse_key("Agent-Pubkey", argv[1], "npub")

    seckey = int(owner_priv, 16)
    if not 1 <= seckey <= N - 1:
        raise SystemExit("FEHLER: Owner-Privkey liegt ausserhalb von [1, n-1].")
    owner_pub = pubkey_of(seckey)

    if owner_pub.hex() == agent_pub:
        raise SystemExit(
            f"FEHLER: Der Privkey gehoert zu {owner_pub.hex()} - das ist der Pubkey,\n"
            "       den du als Agent angegeben hast. NIP-OA verwirft eine\n"
            "       Selbst-Attestierung, das Tag waere ungueltig.\n"
            "\n"
            "       Gebraucht wird der Privkey des OWNERS (dein eigener, der zu\n"
            "       BUZZ_ACP_AGENT_OWNER passt) - nicht der des Agenten aus\n"
            "       BUZZ_AGENTS. Welcher Schluessel welcher ist:\n"
            "         tools/mint-auth-tag.py --pubkey <privkey-hex>"
        )

    msg = auth_message(agent_pub)
    sig = schnorr_sign(msg, seckey, bytes(32))
    if not schnorr_verify(msg, owner_pub, sig):
        raise SystemExit("FEHLER: eigene Signatur verifiziert nicht - nichts ausgegeben.")

    tag = f'["auth","{owner_pub.hex()}","","{sig.hex()}"]'
    print(f"Owner-Pubkey:  {owner_pub.hex()}", file=sys.stderr)
    print("               muss BUZZ_ACP_AGENT_OWNER entsprechen, sonst passt das", file=sys.stderr)
    print("               Tag nicht zu dem, was der Entrypoint zusammensetzt.", file=sys.stderr)
    print(f"Agent-Pubkey:  {agent_pub}", file=sys.stderr)
    print(f"Ganzes Tag:    {tag}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Die Signatur folgt als einzige Zeile auf stdout - ein Wert, kein", file=sys.stderr)
    print("Zeilenumbruch darin. In die .env, ein Eintrag je Agent:", file=sys.stderr)
    print("  BUZZ_AUTH_TAGS=<agent>=<signatur>", file=sys.stderr)
    # Bewusst nur hier und nirgends sonst nochmal: zwei fast gleiche Zeilen
    # laden zum falschen Kopieren ein.
    print(sig.hex())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
