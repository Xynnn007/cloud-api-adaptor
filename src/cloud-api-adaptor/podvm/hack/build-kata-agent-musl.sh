#!/bin/bash
# build-kata-agent-musl.sh - Build a fully static kata-agent (musl) for alinux3 Pod VM.
#
# Why musl: rustup's prebuilt x86_64-unknown-linux-gnu std is linked against a
# newer glibc (often 2.34). Building LIBC=gnu on alinux3 (glibc 2.32) still
# produces a binary that requires GLIBC_2.34. musl static linking avoids that.
#
# Usage (from podvm/):
#   ./hack/build-kata-agent-musl.sh <kata-src-dir> <install-path>
#
# Environment:
#   ARCH                 default: uname -m (x86_64)
#   AGENT_POLICY         default: yes
#   SECCOMP              default: yes
#   INIT_DATA            default: yes
#   LIBSECCOMP_PREFIX    where to install static libseccomp (default: ./build-libseccomp)
#   GPERF_PREFIX         where to install gperf (default: ./build-gperf)
#   LIBSECCOMP_VERSION   default: 2.5.5
#   GPERF_VERSION        default: 3.1

set -euo pipefail

KATA_SRC="$(cd "${1:?kata source directory required}" && pwd)"
INSTALL_PATH="${2:?install path for kata-agent binary required}"

ARCH="${ARCH:-$(uname -m)}"
AGENT_POLICY="${AGENT_POLICY:-yes}"
SECCOMP="${SECCOMP:-yes}"
INIT_DATA="${INIT_DATA:-yes}"
LIBSECCOMP_PREFIX="${LIBSECCOMP_PREFIX:-$(pwd)/build-libseccomp}"
GPERF_PREFIX="${GPERF_PREFIX:-$(pwd)/build-gperf}"
LIBSECCOMP_VERSION="${LIBSECCOMP_VERSION:-2.5.5}"
GPERF_VERSION="${GPERF_VERSION:-3.1}"

AGENT_DIR="${KATA_SRC}/src/agent"
TARGET_TRIPLE="${ARCH}-unknown-linux-musl"
# kata agent Makefile writes to ../../target (repo root), not src/agent/target
OUT_BIN="${KATA_SRC}/target/${TARGET_TRIPLE}/release/kata-agent"

if [ ! -d "${AGENT_DIR}" ]; then
	echo "ERROR: kata agent dir not found: ${AGENT_DIR}" >&2
	exit 1
fi

MUSL_GCC=""
for cand in "${ARCH}-linux-musl-gcc" musl-gcc; do
	if command -v "${cand}" >/dev/null 2>&1; then
		MUSL_GCC="$(command -v "${cand}")"
		break
	fi
done

if [ -z "${MUSL_GCC}" ]; then
	echo "ERROR: musl linker not found (need ${ARCH}-linux-musl-gcc or musl-gcc)" >&2
	echo "Install a musl cross toolchain (e.g. from https://musl.cc/) into PATH." >&2
	exit 1
fi
echo "== Using musl linker: ${MUSL_GCC} =="

if ! command -v protoc >/dev/null 2>&1; then
	echo "ERROR: protoc not found. kata-agent protocols/build.rs invokes protoc." >&2
	echo "Install protobuf-compiler (Debian/Ubuntu) or protobuf-compiler (RHEL/Alinux)." >&2
	exit 1
fi

# musl-gcc does not search glibc's /usr/include. Kernel UAPI headers from
# linux-libc-dev (linux/*.h, asm/unistd.h) are ABI-stable; -idirafter uses
# them only when the musl sysroot does not already provide the header.
MUSL_CFLAGS=(-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=1 -O2)
if [ -d /usr/include/linux ]; then
	MUSL_CFLAGS+=(-idirafter /usr/include)
fi
GNU_INC="/usr/include/${ARCH}-linux-gnu"
if [ -d "${GNU_INC}/asm" ]; then
	MUSL_CFLAGS+=(-idirafter "${GNU_INC}")
fi
if ! printf '#include <linux/seccomp.h>\n#include <linux/filter.h>\n#include <linux/audit.h>\n#include <asm/unistd.h>\n' \
	| "${MUSL_GCC}" "${MUSL_CFLAGS[@]}" -E - >/dev/null 2>&1; then
	echo "ERROR: kernel UAPI headers are not visible to ${MUSL_GCC}." >&2
	echo "Install linux-libc-dev (Debian/Ubuntu) or linux-headers (Alpine)." >&2
	exit 1
fi

CARGO_DIR="${CARGO_HOME:-${HOME}/.cargo}"
mkdir -p "${CARGO_DIR}"
# Append the linker table; do not overwrite an existing cargo config.
if [ ! -f "${CARGO_DIR}/config.toml" ] || ! grep -q "^\[target\.${TARGET_TRIPLE}\]" "${CARGO_DIR}/config.toml"; then
	printf '\n[target.%s]\nlinker = "%s"\n' "${TARGET_TRIPLE}" "${MUSL_GCC}" >> "${CARGO_DIR}/config.toml"
fi

install_rustup() {
	local triple url tmp urls ok
	case "$(uname -m)" in
		x86_64|amd64) triple="x86_64-unknown-linux-gnu" ;;
		aarch64|arm64) triple="aarch64-unknown-linux-gnu" ;;
		*)
			echo "ERROR: unsupported host arch for rustup: $(uname -m)" >&2
			exit 1
			;;
	esac
	tmp="$(mktemp)"
	urls=(
		"https://static.rust-lang.org/rustup/dist/${triple}/rustup-init"
		"https://mirrors.ustc.edu.cn/rust-static/rustup/dist/${triple}/rustup-init"
	)
	ok=0
	for url in "${urls[@]}"; do
		echo "== Downloading rustup-init from ${url} =="
		if curl -fL --retry 3 --retry-delay 2 "${url}" -o "${tmp}"; then
			ok=1
			break
		fi
	done
	if [ "${ok}" -ne 1 ]; then
		echo "ERROR: failed to download rustup-init" >&2
		rm -f "${tmp}"
		exit 1
	fi
	sh "${tmp}" -y --profile minimal --default-toolchain none --no-modify-path
	rm -f "${tmp}"
	# shellcheck disable=SC1091
	[ -f "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"
	export PATH="${HOME}/.cargo/bin:${PATH}"
}

if ! command -v rustup >/dev/null 2>&1; then
	if [ -x "${HOME}/.cargo/bin/rustup" ]; then
		export PATH="${HOME}/.cargo/bin:${PATH}"
	else
		install_rustup
	fi
fi
if ! command -v cargo >/dev/null 2>&1 && [ -x "${HOME}/.cargo/bin/cargo" ]; then
	export PATH="${HOME}/.cargo/bin:${PATH}"
fi
if ! command -v rustup >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
	echo "ERROR: rustup/cargo not available after install" >&2
	exit 1
fi

# rust-toolchain.toml pins the channel. Install it explicitly; rustup no longer
# promises to auto-install a missing toolchain.
echo "== Installing Rust toolchain pinned by kata and musl target ${TARGET_TRIPLE} =="
(
	cd "${AGENT_DIR}"
	rustup toolchain install
	rustup target add "${TARGET_TRIPLE}"
)

install_static_libseccomp() {
	local workdir
	workdir="$(mktemp -d --tmpdir build-libseccomp.XXXXX)"
	# shellcheck disable=SC2064
	trap "rm -rf '${workdir}'" EXIT

	mkdir -p "${GPERF_PREFIX}" "${LIBSECCOMP_PREFIX}"

	if ! command -v gperf >/dev/null 2>&1; then
		echo "== Installing/building gperf ${GPERF_VERSION} =="
		# Prefer distro package when available (avoids flaky ftp.gnu.org)
		if command -v yum >/dev/null 2>&1 && yum install -y gperf; then
			:
		else
			local gperf_ok=0
			local mirror
			for mirror in \
				"https://ftpmirror.gnu.org/gperf/gperf-${GPERF_VERSION}.tar.gz" \
				"https://ftp.gnu.org/gnu/gperf/gperf-${GPERF_VERSION}.tar.gz" \
				"https://mirrors.kernel.org/gnu/gperf/gperf-${GPERF_VERSION}.tar.gz"; do
				echo "Trying ${mirror}"
				if curl -fL --retry 3 --retry-delay 2 "${mirror}" -o "${workdir}/gperf.tar.gz"; then
					gperf_ok=1
					break
				fi
			done
			if [ "${gperf_ok}" -ne 1 ]; then
				echo "ERROR: failed to download gperf" >&2
				exit 1
			fi
			tar -C "${workdir}" -xzf "${workdir}/gperf.tar.gz"
			(
				cd "${workdir}/gperf-${GPERF_VERSION}"
				./configure --prefix="${GPERF_PREFIX}"
				make -j"$(nproc)"
				make install
			)
			export PATH="${GPERF_PREFIX}/bin:${PATH}"
		fi
	fi
	command -v gperf >/dev/null 2>&1 || {
		echo "ERROR: gperf not available after install" >&2
		exit 1
	}

	echo "== Building static libseccomp ${LIBSECCOMP_VERSION} with musl -> ${LIBSECCOMP_PREFIX} =="
	curl -fL --retry 3 --retry-delay 2 \
		"https://github.com/seccomp/libseccomp/releases/download/v${LIBSECCOMP_VERSION}/libseccomp-${LIBSECCOMP_VERSION}.tar.gz" \
		-o "${workdir}/libseccomp.tar.gz"
	tar -C "${workdir}" -xzf "${workdir}/libseccomp.tar.gz"
	(
		cd "${workdir}/libseccomp-${LIBSECCOMP_VERSION}"
		# musl lacks some FORTIFY_SOURCE=2 helpers; match kata's install_libseccomp.sh.
		# MUSL_CFLAGS also adds kernel UAPI include paths (see above).
		CC="${MUSL_GCC}" CFLAGS="${MUSL_CFLAGS[*]}" \
			./configure --prefix="${LIBSECCOMP_PREFIX}" --enable-static --disable-shared \
			--host="${ARCH}-linux-musl"
		make -j"$(nproc)"
		make install
	)
	trap - EXIT
	rm -rf "${workdir}"
}

if [ "${SECCOMP}" = "yes" ]; then
	if [ ! -f "${LIBSECCOMP_PREFIX}/lib/libseccomp.a" ]; then
		install_static_libseccomp
	fi
	export LIBSECCOMP_LINK_TYPE=static
	export LIBSECCOMP_LIB_PATH="${LIBSECCOMP_PREFIX}/lib"
fi

echo "== Building kata-agent (LIBC=musl, SECCOMP=${SECCOMP}) =="
cd "${AGENT_DIR}"
AGENT_POLICY="${AGENT_POLICY}" SECCOMP="${SECCOMP}" INIT_DATA="${INIT_DATA}" LIBC=musl make

if [ ! -x "${OUT_BIN}" ]; then
	echo "ERROR: expected binary missing: ${OUT_BIN}" >&2
	exit 1
fi

# Sanity: must not pull in glibc / dynamic libs
if command -v ldd >/dev/null 2>&1; then
	ldd_out="$(ldd "${OUT_BIN}" 2>&1 || true)"
	if echo "${ldd_out}" | grep -qE 'libc\.so\.6|libseccomp\.so|ld-linux'; then
		echo "ERROR: kata-agent is dynamically linked (expected static musl):" >&2
		echo "${ldd_out}" >&2
		exit 1
	fi
fi
if command -v objdump >/dev/null 2>&1; then
	if objdump -T "${OUT_BIN}" 2>/dev/null | grep -q 'GLIBC_'; then
		echo "ERROR: kata-agent still references GLIBC_* symbols" >&2
		objdump -T "${OUT_BIN}" | grep 'GLIBC_' | head -20 >&2 || true
		exit 1
	fi
fi

install -D --compare "${OUT_BIN}" "${INSTALL_PATH}"
echo "== Installed static kata-agent -> ${INSTALL_PATH} =="
file "${INSTALL_PATH}" || true
