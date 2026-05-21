#!/usr/bin/env bash
# Install llama.cpp into ${LLAMACPP_HOME} (default ~/.local/llama.cpp).
#
# Backend selection (set LLAMACPP_BACKEND to override, default auto):
#   prebuilt     fetch the upstream ggml-org release asset for this platform.
#                macOS gets macos-${ARCH}; Linux/Windows default to the portable
#                Vulkan build (upstream ships CUDA only for Windows).
#   mac-source   build llama.cpp from a git ref (default master) with
#                -DGGML_METAL=1. Auto-selected on Mac so the binary tracks
#                upstream main and the flag set matches the README/help.
#                Pin to a tag with LLAMACPP_REF=bN if reproducibility is needed.
#   cuda-source build llama.cpp from the matching git ref with -DGGML_CUDA=ON.
#                Auto-selected on Linux when nvidia-smi + nvcc + cmake + ninja +
#                git are all present; gets ~2x throughput vs Vulkan on NVIDIA
#                and removes the inter-token stalls that trigger opencode
#                ECONNRESETs.
#   auto         mac-source on Mac, cuda-source on Linux+CUDA, else prebuilt.
#
# Env overrides:
#   LLAMACPP_HOME         target install dir (default ~/.local/llama.cpp)
#   LLAMACPP_TAG          pin to a specific release tag (default: latest;
#                         only consulted by the prebuilt backend)
#   LLAMACPP_REPO         git repo for source builds
#                         (default https://github.com/ggml-org/llama.cpp.git)
#   LLAMACPP_REF          git ref for source builds (default master; can be
#                         a tag, branch, or commit sha)
#   LLAMACPP_BACKEND      auto | prebuilt | mac-source | cuda-source (default auto)
#   LLAMACPP_FLAVOR       prebuilt asset override (e.g. ubuntu-vulkan-x64)
#   LLAMACPP_CMAKE_EXTRA  extra flags appended to cmake configure (cuda-source)
#   LLAMACPP_BUILD_JOBS   source build parallelism (default Slurm CPUs or nproc)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

have python3 || die "python3 is required"

PLATFORM="$(detect_platform)"
ARCH="$(detect_arch)"
GPU="$(detect_gpu)"

BACKEND="${LLAMACPP_BACKEND:-auto}"
if [[ "${BACKEND}" == "auto" ]]; then
  if [[ "${PLATFORM}" == "mac" ]] && have cmake && have ninja && have git; then
    BACKEND="mac-source"
  elif [[ "${PLATFORM}" == "linux" && "${GPU}" == "cuda" ]] \
      && have nvcc && have cmake && have ninja && have git; then
    BACKEND="cuda-source"
  else
    BACKEND="prebuilt"
  fi
fi

case "${BACKEND}" in
  prebuilt|mac-source|cuda-source) ;;
  *) die "unknown LLAMACPP_BACKEND: ${BACKEND}" ;;
esac

LLAMACPP_REPO="${LLAMACPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
LLAMACPP_REF="${LLAMACPP_REF:-master}"

# The release-tag resolution is only meaningful for the prebuilt backend (which
# downloads a release asset). Source backends pull a git ref directly, so we
# skip the GitHub API call there.
TAG=""
if [[ "${BACKEND}" == "prebuilt" ]]; then
  API="https://api.github.com/repos/ggml-org/llama.cpp/releases"
  have curl || die "curl is required for prebuilt install"
  if [[ -n "${LLAMACPP_TAG:-}" ]]; then
    release_url="${API}/tags/${LLAMACPP_TAG}"
  else
    release_url="${API}/latest"
  fi
  echo "resolving llama.cpp release (${release_url})..."
  release_json="$(curl -fsSL "${release_url}")"
  TAG="$(printf '%s' "${release_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
  echo "tag:     ${TAG}"
fi
echo "backend: ${BACKEND}"
if [[ "${BACKEND}" =~ -source$ ]]; then
  echo "repo:    ${LLAMACPP_REPO}"
  echo "ref:     ${LLAMACPP_REF}"
fi

mkdir -p "${LLAMACPP_HOME}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

install_prebuilt() {
  have unzip || die "unzip is required for prebuilt install"
  have tar || die "tar is required for prebuilt install"

  local flavor="${LLAMACPP_FLAVOR:-}"
  if [[ -z "${flavor}" ]]; then
    case "${PLATFORM}" in
      mac)           flavor="macos-${ARCH}" ;;
      linux|wsl)     flavor="ubuntu-vulkan-${ARCH}" ;;
      windows)       flavor="win-vulkan-${ARCH}" ;;
      *) die "cannot infer llama.cpp release flavor for ${PLATFORM}" ;;
    esac
  fi

  local asset_url
  asset_url="$(printf '%s' "${release_json}" | python3 -c '
import json, re, sys
flavor = sys.argv[1]
data = json.load(sys.stdin)
pat = re.compile(rf"llama-.*-bin-{re.escape(flavor)}\.(zip|tar\.gz)$")
for asset in data["assets"]:
    if pat.search(asset["name"]):
        print(asset["browser_download_url"])
        sys.exit(0)
sys.exit(1)
' "${flavor}")" || die "no asset matching flavor '${flavor}' in release ${TAG}"

  local asset_name
  asset_name="$(basename "${asset_url}")"
  echo "flavor:  ${flavor}"
  echo "asset:   ${asset_name}"

  echo "downloading ${asset_url}..."
  curl -fsSL -o "${tmpdir}/pkg" "${asset_url}"
  mkdir -p "${tmpdir}/unpacked"
  case "${asset_name}" in
    *.zip)    unzip -q -o "${tmpdir}/pkg" -d "${tmpdir}/unpacked" ;;
    *.tar.gz) tar -xzf "${tmpdir}/pkg" -C "${tmpdir}/unpacked" ;;
    *) die "unknown archive format: ${asset_name}" ;;
  esac

  local binary_dir
  binary_dir="$(find "${tmpdir}/unpacked" -type f \( -name 'llama-server' -o -name 'llama-server.exe' \) -print -quit | xargs -I{} dirname {})"
  [[ -n "${binary_dir}" ]] || die "llama-server not found in downloaded archive"
  cp -R "${binary_dir}/." "${LLAMACPP_HOME}/"

  printf '%s\n' "${TAG}" > "${LLAMACPP_HOME}/VERSION"
}

install_cuda_source() {
  [[ "${PLATFORM}" == "linux" || "${PLATFORM}" == "wsl" ]] \
    || die "cuda-source backend only supported on Linux/WSL (got ${PLATFORM})"
  have nvcc || die "nvcc not found in PATH; install the CUDA toolkit (e.g. /opt/cuda/bin)"
  have cmake || die "cmake is required for cuda-source backend"
  have ninja || die "ninja is required for cuda-source backend"
  have git || die "git is required for cuda-source backend"

  local src="${tmpdir}/llama.cpp"
  local build="${tmpdir}/build"
  local install="${tmpdir}/install"

  echo "cloning ${LLAMACPP_REPO} @ ${LLAMACPP_REF}..."
  git clone --depth 1 --branch "${LLAMACPP_REF}" \
    "${LLAMACPP_REPO}" "${src}" 2>&1 | tail -2
  local head_sha
  head_sha="$(git -C "${src}" rev-parse HEAD)"

  export CUDACXX="${CUDACXX:-$(command -v nvcc)}"
  echo "configuring (GGML_CUDA=ON, native arch)..."
  # shellcheck disable=SC2086
  cmake -S "${src}" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${install}" \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_CUDA=ON \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    ${LLAMACPP_CMAKE_EXTRA:-} >"${tmpdir}/cmake-configure.log" 2>&1 \
      || { tail -40 "${tmpdir}/cmake-configure.log" >&2; die "cmake configure failed"; }

  echo "building (this takes a few minutes)..."
  local build_jobs="${LLAMACPP_BUILD_JOBS:-${SLURM_CPUS_PER_TASK:-$(nproc)}}"
  cmake --build "${build}" -j"${build_jobs}" >"${tmpdir}/cmake-build.log" 2>&1 \
    || { tail -40 "${tmpdir}/cmake-build.log" >&2; die "cmake build failed"; }

  echo "installing..."
  cmake --install "${build}" >"${tmpdir}/cmake-install.log" 2>&1 \
    || { tail -40 "${tmpdir}/cmake-install.log" >&2; die "cmake install failed"; }

  # Flatten bin/ and lib/ into LLAMACPP_HOME so the layout matches the prebuilt
  # release asset that server_start_llamacpp.sh expects (flat directory with
  # llama-server next to all .so files). Wipe the previous install first so old
  # backend libraries (e.g. libggml-vulkan.so) don't linger.
  find "${LLAMACPP_HOME}" -mindepth 1 -maxdepth 1 \
    \( -name 'llama-*' -o -name 'lib*.so*' -o -name 'VERSION' \) -exec rm -rf {} +

  cp "${install}/bin/llama-server" "${LLAMACPP_HOME}/"
  # Copy every shared library and its symlinks. Install ships them under lib/.
  local libdir="${install}/lib"
  [[ -d "${libdir}" ]] || libdir="${install}/lib64"
  [[ -d "${libdir}" ]] || die "neither ${install}/lib nor ${install}/lib64 exists"
  find "${libdir}" -maxdepth 1 \( -name 'lib*.so' -o -name 'lib*.so.*' \) \
    -exec cp -P {} "${LLAMACPP_HOME}/" \;

  # Some CMake installs copy versioned libraries without the SONAME symlink.
  # Recreate those links in the flattened runtime dir so direct launches work.
  if have readelf; then
    local so soname
    for so in "${LLAMACPP_HOME}"/lib*.so.*; do
      [[ -e "${so}" ]] || continue
      soname="$(readelf -d "${so}" 2>/dev/null | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p' | head -1)"
      [[ -n "${soname}" ]] && ln -sfn "$(basename "${so}")" "${LLAMACPP_HOME}/${soname}"
    done
  fi

  printf '%s+cuda (%s)\n' "${LLAMACPP_REF}" "${head_sha:0:12}" > "${LLAMACPP_HOME}/VERSION"
}

install_mac_source() {
  [[ "${PLATFORM}" == "mac" ]] || die "mac-source backend only supported on macOS"
  have cmake || die "cmake is required for mac-source backend (brew install cmake)"
  have ninja || die "ninja is required for mac-source backend (brew install ninja)"
  have git   || die "git is required"

  local src="${tmpdir}/llama.cpp"
  local build="${tmpdir}/build"
  local install="${tmpdir}/install"

  echo "cloning ${LLAMACPP_REPO} @ ${LLAMACPP_REF}..."
  git clone --depth 1 --branch "${LLAMACPP_REF}" \
    "${LLAMACPP_REPO}" "${src}" 2>&1 | tail -2
  local head_sha
  head_sha="$(git -C "${src}" rev-parse HEAD)"

  echo "configuring (GGML_METAL=ON)..."
  cmake -S "${src}" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${install}" \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    ${LLAMACPP_CMAKE_EXTRA:-} >"${tmpdir}/cmake-configure.log" 2>&1 \
      || { tail -40 "${tmpdir}/cmake-configure.log" >&2; die "cmake configure failed"; }

  echo "building (this takes a few minutes)..."
  cmake --build "${build}" -j"$(detect_physical_cores)" >"${tmpdir}/cmake-build.log" 2>&1 \
    || { tail -40 "${tmpdir}/cmake-build.log" >&2; die "cmake build failed"; }

  echo "installing..."
  cmake --install "${build}" >"${tmpdir}/cmake-install.log" 2>&1 \
    || { tail -40 "${tmpdir}/cmake-install.log" >&2; die "cmake install failed"; }

  # Flatten bin/ + lib/ into LLAMACPP_HOME (matches prebuilt layout).
  find "${LLAMACPP_HOME}" -mindepth 1 -maxdepth 1 \
    \( -name 'llama-*' -o -name 'lib*.dylib*' -o -name 'VERSION' \
       -o -name 'ggml-metal*' -o -name '*.metallib' \) -exec rm -rf {} +
  mkdir -p "${LLAMACPP_HOME}"
  cp "${install}/bin/llama-server" "${LLAMACPP_HOME}/"
  local libdir="${install}/lib"
  [[ -d "${libdir}" ]] || die "${install}/lib missing"
  # llama-server resolves a sibling libllama-server-impl.dylib via @rpath, but
  # upstream's CMake install target does not ship that dylib (it stays under
  # ${build}/bin). Copy it explicitly alongside the rest. Older layouts kept
  # the shared libs under ${install}/lib; recent layouts spread them across
  # ${install}/bin too — globbing both keeps both working.
  for src in "${libdir}" "${install}/bin" "${build}/bin"; do
    [[ -d "${src}" ]] || continue
    find "${src}" -maxdepth 1 \( -name 'lib*.dylib' -o -name 'lib*.dylib.*' \) \
      -exec cp -P {} "${LLAMACPP_HOME}/" \;
  done
  # ggml-metal.metallib (the precompiled Metal shaders) lives next to the
  # binary; without it llama-server fails to launch the Metal backend.
  find "${install}" \( -name 'ggml-metal*.metallib' -o -name 'default.metallib' \) \
    -exec cp {} "${LLAMACPP_HOME}/" \; 2>/dev/null || true

  printf '%s+metal (%s)\n' "${LLAMACPP_REF}" "${head_sha:0:12}" > "${LLAMACPP_HOME}/VERSION"
}

case "${BACKEND}" in
  prebuilt)    install_prebuilt ;;
  mac-source)  install_mac_source ;;
  cuda-source) install_cuda_source ;;
esac

server="${LLAMACPP_HOME}/llama-server"
[[ "${PLATFORM}" == "windows" ]] && server="${LLAMACPP_HOME}/llama-server.exe"
chmod +x "${server}" 2>/dev/null || true

if [[ "${PLATFORM}" != "windows" ]]; then
  mkdir -p "${HOME}/.local/bin"
  cat > "${HOME}/.local/bin/llama-server" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
root="\${LLAMACPP_HOME:-${LLAMACPP_HOME}}"
cuda_lib=""
if [[ -n "\${CUDA_HOME:-}" && -d "\${CUDA_HOME}/lib64" ]]; then
  cuda_lib="\${CUDA_HOME}/lib64"
elif [[ -d /usr/local/cuda-13.1/lib64 ]]; then
  cuda_lib=/usr/local/cuda-13.1/lib64
elif [[ -d /usr/local/cuda/lib64 ]]; then
  cuda_lib=/usr/local/cuda/lib64
fi
if [[ -n "\${cuda_lib}" ]]; then
  export LD_LIBRARY_PATH="\${root}:\${cuda_lib}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
else
  export LD_LIBRARY_PATH="\${root}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
fi
export DYLD_LIBRARY_PATH="\${root}\${DYLD_LIBRARY_PATH:+:\${DYLD_LIBRARY_PATH}}"
exec "\${root}/llama-server" "\$@"
WRAP
  chmod +x "${HOME}/.local/bin/llama-server"
fi

echo "installed llama.cpp $(cat "${LLAMACPP_HOME}/VERSION") at ${LLAMACPP_HOME}"
if [[ -x "${server}" ]]; then
  # macOS uses DYLD_LIBRARY_PATH; Linux uses LD_LIBRARY_PATH. Set both so the
  # post-install --version probe finds libllama-common.dylib / .so regardless.
  DYLD_LIBRARY_PATH="${LLAMACPP_HOME}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}" \
  LD_LIBRARY_PATH="${LLAMACPP_HOME}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${server}" --version 2>&1 | head -5 || true
fi
