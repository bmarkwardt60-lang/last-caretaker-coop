#!/usr/bin/env python3
"""Two-player LAN pose relay for the Last Caretaker UE4SS prototype.

The game mod exchanges one small pose file with this process. Pose packets use
UDP and are intentionally unreliable; the newest transform replaces older ones.
This prototype has no encryption and should stay on a trusted LAN.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import threading
import time
import uuid
from pathlib import Path
from typing import Any


PROTOCOL_VERSION = 1
DEFAULT_PORT = 28770
MAX_PLAYERS = 2
MAX_PACKET_BYTES = 1200
PEER_TIMEOUT_SECONDS = 15.0


def default_data_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    base = Path(local_app_data) if local_app_data else Path.home()
    return base / "Voyage" / "Saved" / "LastCaretakerCoop"


def encode(packet: dict[str, Any]) -> bytes:
    return json.dumps(packet, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def decode(data: bytes) -> dict[str, Any] | None:
    if len(data) > MAX_PACKET_BYTES:
        return None
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or value.get("v") != PROTOCOL_VERSION:
        return None
    return value


def atomic_write(path: Path, contents: str) -> None:
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(contents, encoding="utf-8", newline="")
    os.replace(temp, path)


class RelayServer:
    def __init__(self, bind: str, port: int, session: str, token: str) -> None:
        self.address = (bind, port)
        self.session = session
        self.token = token
        self.peers: dict[str, dict[str, Any]] = {}
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(self.address)
        self.socket.settimeout(0.5)
        self.stop_event = threading.Event()

    def send(self, address: tuple[str, int], packet: dict[str, Any]) -> None:
        try:
            self.socket.sendto(encode(packet), address)
        except OSError:
            pass

    def packet_for(self, packet_type: str, **fields: Any) -> dict[str, Any]:
        return {"v": PROTOCOL_VERSION, "type": packet_type, "session": self.session, **fields}

    def run(self) -> None:
        print(f"LAN relay listening on {self.address[0]}:{self.address[1]} (2 slots)")
        while not self.stop_event.is_set():
            try:
                raw, address = self.socket.recvfrom(MAX_PACKET_BYTES + 1)
            except socket.timeout:
                self.expire_peers()
                continue
            except OSError:
                break

            self.expire_peers()
            packet = decode(raw)
            if packet is None or packet.get("session") != self.session:
                continue
            if packet.get("token") != self.token:
                self.send(address, self.packet_for("error", reason="bad_token"))
                continue

            client_id = packet.get("client_id")
            if not isinstance(client_id, str) or len(client_id) > 64:
                continue

            if packet.get("type") == "hello":
                self.register_peer(client_id, address, packet.get("name", "Player"))
            elif packet.get("type") == "pose":
                self.relay_pose(client_id, address, packet)
            elif packet.get("type") == "bye":
                self.remove_peer(client_id)

    def register_peer(self, client_id: str, address: tuple[str, int], name: Any) -> None:
        if client_id not in self.peers and len(self.peers) >= MAX_PLAYERS:
            self.send(address, self.packet_for("error", reason="session_full"))
            return

        clean_name = name if isinstance(name, str) else "Player"
        clean_name = clean_name[:40]
        is_new = client_id not in self.peers
        previous_address = self.peers.get(client_id, {}).get("address")
        self.peers[client_id] = {
            "address": address,
            "name": clean_name,
            "last_seen": time.monotonic(),
            "pose": None,
        }

        if not is_new and previous_address == address:
            return

        roster = [
            {"client_id": peer_id, "name": peer["name"]}
            for peer_id, peer in self.peers.items()
            if peer_id != client_id
        ]
        self.send(address, self.packet_for("welcome", client_id=client_id, peers=roster))
        for peer_id, peer in self.peers.items():
            if peer_id != client_id and peer["pose"] is not None:
                self.send(address, peer["pose"])

        if is_new:
            joined = self.packet_for("peer_joined", client_id=client_id, name=clean_name)
            for peer_id, peer in self.peers.items():
                if peer_id != client_id:
                    self.send(peer["address"], joined)
            print(f"{clean_name} joined ({len(self.peers)}/{MAX_PLAYERS})")

    def relay_pose(self, client_id: str, address: tuple[str, int], packet: dict[str, Any]) -> None:
        peer = self.peers.get(client_id)
        if peer is None or peer["address"] != address:
            return
        try:
            epoch = packet["epoch"]
            sequence = int(packet["seq"])
            pose = [float(packet[key]) for key in ("x", "y", "z", "pitch", "yaw", "roll")]
        except (KeyError, TypeError, ValueError, OverflowError):
            return
        if not isinstance(epoch, str) or len(epoch) > 64:
            return
        if not all(-1.0e8 < value < 1.0e8 for value in pose):
            return

        peer["last_seen"] = time.monotonic()
        forwarded = self.packet_for(
            "pose",
            client_id=client_id,
            epoch=epoch,
            seq=sequence,
            x=pose[0], y=pose[1], z=pose[2],
            pitch=pose[3], yaw=pose[4], roll=pose[5],
        )
        peer["pose"] = forwarded
        for other_id, other in self.peers.items():
            if other_id != client_id:
                self.send(other["address"], forwarded)

    def remove_peer(self, client_id: str) -> None:
        peer = self.peers.pop(client_id, None)
        if peer is None:
            return
        left = self.packet_for("peer_left", client_id=client_id)
        for other in self.peers.values():
            self.send(other["address"], left)
        print(f"{peer['name']} left ({len(self.peers)}/{MAX_PLAYERS})")

    def expire_peers(self) -> None:
        now = time.monotonic()
        expired = [
            client_id for client_id, peer in self.peers.items()
            if now - peer["last_seen"] > PEER_TIMEOUT_SECONDS
        ]
        for client_id in expired:
            self.remove_peer(client_id)

    def close(self) -> None:
        self.stop_event.set()
        self.socket.close()


def read_pose(path: Path) -> tuple[str, int, tuple[float, float, float, float, float, float]] | None:
    try:
        if time.time() - path.stat().st_mtime > 2.0:
            return None
        fields = path.read_text(encoding="utf-8").strip().split(",")
        if len(fields) != 8 or not fields[0] or len(fields[0]) > 64:
            return None
        epoch = fields[0]
        seq = int(fields[1])
        pose = tuple(float(field) for field in fields[2:])
        if not all(-1.0e8 < value < 1.0e8 for value in pose):
            return None
        return epoch, seq, pose  # type: ignore[return-value]
    except (OSError, UnicodeDecodeError, ValueError, OverflowError):
        return None


def parse_host(value: str, default_port: int) -> tuple[str, int]:
    if ":" not in value:
        return value, default_port
    host, port_text = value.rsplit(":", 1)
    try:
        return host, int(port_text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("host must be an IP or hostname, optionally followed by :port") from exc


def run_client(
    *,
    server_address: tuple[str, int],
    data_dir: Path,
    session: str,
    token: str,
    name: str,
    stop_event: threading.Event,
) -> None:
    data_dir.mkdir(parents=True, exist_ok=True)
    outgoing_path = data_dir / "outgoing.pose"
    incoming_path = data_dir / "incoming.pose"
    client_id = uuid.uuid4().hex
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    sock.settimeout(0.05)
    last_hello = 0.0
    last_sequence: tuple[str, int] | None = None
    last_peer_id: str | None = None
    last_peer_epoch: str | None = None
    last_peer_sequence = -1

    print(f"Pose bridge active as {name}; data folder: {data_dir}")
    print(f"Session: {session}; relay: {server_address[0]}:{server_address[1]}")
    try:
        while not stop_event.is_set():
            now = time.monotonic()
            if now - last_hello >= 2.0:
                hello = {
                    "v": PROTOCOL_VERSION, "type": "hello", "session": session,
                    "token": token, "client_id": client_id, "name": name,
                }
                sock.sendto(encode(hello), server_address)
                last_hello = now

            current = read_pose(outgoing_path)
            if current is not None and current[:2] != last_sequence:
                epoch, seq, (x, y, z, pitch, yaw, roll) = current
                packet = {
                    "v": PROTOCOL_VERSION, "type": "pose", "session": session,
                    "token": token, "client_id": client_id, "epoch": epoch, "seq": seq,
                    "x": x, "y": y, "z": z,
                    "pitch": pitch, "yaw": yaw, "roll": roll,
                }
                sock.sendto(encode(packet), server_address)
                last_sequence = (epoch, seq)

            try:
                raw, source = sock.recvfrom(MAX_PACKET_BYTES + 1)
            except socket.timeout:
                continue
            except OSError:
                break

            if source != server_address:
                continue
            packet = decode(raw)
            if packet is None or packet.get("session") != session:
                continue
            kind = packet.get("type")

            if kind == "error":
                print(f"Relay rejected the session: {packet.get('reason', 'unknown')}")
            elif kind == "welcome":
                print("Connected to relay.")
                for peer in packet.get("peers", []):
                    if isinstance(peer, dict):
                        print(f"Peer already in session: {peer.get('name', 'Player')}")
            elif kind == "peer_joined":
                print(f"Peer joined: {packet.get('name', 'Player')}")
            elif kind == "peer_left":
                if packet.get("client_id") == last_peer_id:
                    last_peer_id = None
                    last_peer_epoch = None
                    last_peer_sequence = -1
                    try:
                        incoming_path.unlink(missing_ok=True)
                    except OSError:
                        pass
                print("Peer left the session.")
            elif kind == "pose":
                peer_id = packet.get("client_id")
                if not isinstance(peer_id, str) or peer_id == client_id:
                    continue
                try:
                    epoch = packet["epoch"]
                    sequence = int(packet["seq"])
                    pose = [float(packet[key]) for key in ("x", "y", "z", "pitch", "yaw", "roll")]
                except (KeyError, TypeError, ValueError, OverflowError):
                    continue
                if not isinstance(epoch, str) or len(epoch) > 64:
                    continue
                if len(pose) != 6 or not all(-1.0e8 < value < 1.0e8 for value in pose):
                    continue
                if peer_id != last_peer_id:
                    last_peer_id = peer_id
                    last_peer_epoch = None
                    last_peer_sequence = -1
                if epoch != last_peer_epoch:
                    last_peer_epoch = epoch
                    last_peer_sequence = -1
                if sequence > last_peer_sequence:
                    line = f"{peer_id},{epoch},{sequence}," + ",".join(f"{value:.3f}" for value in pose) + "\n"
                    atomic_write(incoming_path, line)
                    last_peer_sequence = sequence
    finally:
        try:
            sock.sendto(encode({
                "v": PROTOCOL_VERSION, "type": "bye", "session": session,
                "token": token, "client_id": client_id,
            }), server_address)
        except OSError:
            pass
        sock.close()


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Two-player LAN pose bridge for The Last Caretaker.")
    subparsers = parser.add_subparsers(dest="mode", required=True)
    for mode in ("host", "join"):
        sub = subparsers.add_parser(mode)
        sub.add_argument("--name", required=True, help="Display name for this player")
        sub.add_argument("--session", required=True, help="Shared session label")
        sub.add_argument("--token", required=True, help="Shared LAN session token")
        sub.add_argument("--data-dir", type=Path, default=default_data_dir())
        sub.add_argument("--port", type=int, default=DEFAULT_PORT)
        if mode == "host":
            sub.add_argument("--bind", default="0.0.0.0", help="Local interface for the LAN relay")
        else:
            sub.add_argument("--host", required=True, help="Host LAN IP or hostname")
    return parser


def main() -> int:
    args = make_parser().parse_args()
    stop_event = threading.Event()

    def stop(_signum: int, _frame: Any) -> None:
        stop_event.set()

    signal.signal(signal.SIGINT, stop)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, stop)

    server: RelayServer | None = None
    server_thread: threading.Thread | None = None
    if args.mode == "host":
        server = RelayServer(args.bind, args.port, args.session, args.token)
        server_thread = threading.Thread(target=server.run, name="coop-lan-relay", daemon=True)
        server_thread.start()
        server_address = ("127.0.0.1", args.port)
        print(f"Tell the other player to join {args.name}'s LAN IP on UDP {args.port}.")
    else:
        server_address = parse_host(args.host, args.port)

    try:
        run_client(
            server_address=server_address,
            data_dir=args.data_dir,
            session=args.session,
            token=args.token,
            name=args.name,
            stop_event=stop_event,
        )
    except KeyboardInterrupt:
        stop_event.set()
    finally:
        if server is not None:
            server.close()
        if server_thread is not None:
            server_thread.join(timeout=1.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
