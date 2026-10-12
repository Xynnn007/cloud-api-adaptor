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

CARGO_DIR="${CARGO_HOME:-${HOME}/.cargo}"
mkdir -p "${CARGO_DIR}"
if [ -n "${MUSL_GCC}" ]; then
	cat > "${CARGO_DIR}/config.toml" <<EOF
[target.${TARGET_TRIPLE}]
linker = "${MUSL_GCC}"
EOF
	echo "== Using musl linker: ${MUSL_GCC} =="
else
	echo "ERROR: musl linker not found (need ${ARCH}-linux-musl-gcc or musl-gcc)" >&2
	echo "Install a musl cross toolchain (e.g. from https://musl.cc/) into PATH." >&2
	exit 1
fi

# Install musl std for the toolchain pinned by kata's rust-toolchain.toml
# (may differ from the Dockerfile's default stable).
if command -v rustup >/dev/null 2>&1; then
	echo "== Active rust toolchain in ${AGENT_DIR} =="
	(cd "${AGENT_DIR}" && rustup show active-toolchain || rustup show)
	(cd "${AGENT_DIR}" && rustup target add "${TARGET_TRIPLE}")
fi

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
		# musl lacks some FORTIFY_SOURCE=2 helpers; match kata's install_libseccomp.sh
		CC="${MUSL_GCC}" CFLAGS="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=1 -O2" \
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
