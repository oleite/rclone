#!/bin/sh
set -eu

repository_root=$(cd "${SRCROOT}/../../.." && pwd)
output="${DERIVED_FILE_DIR}/librclone_cloudmount.a"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
clang_path=$(xcrun --sdk macosx --find clang)
archive_dir="${DERIVED_FILE_DIR}/cloudmount-archives"
mkdir -p "${archive_dir}"

archives=""
for architecture in ${ARCHS}; do
    case "${architecture}" in
        arm64) go_arch=arm64 ;;
        x86_64) go_arch=amd64 ;;
        *) echo "unsupported Xcode architecture: ${architecture}" >&2; exit 1 ;;
    esac
    archive="${archive_dir}/librclone_cloudmount_${architecture}.a"
    (
        cd "${repository_root}"
        SDKROOT="${sdk_path}" CGO_ENABLED=1 GOOS=darwin GOARCH="${go_arch}" CC="${clang_path}" \
            CGO_CFLAGS="-isysroot ${sdk_path} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
            CGO_LDFLAGS="-isysroot ${sdk_path} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
            go build -buildmode=c-archive -o "${archive}" ./librclone/cloudmount
    )
    archives="${archives} ${archive}"
done

set -- ${archives}
if [ "$#" -eq 1 ]; then
    cp "$1" "${output}"
else
    xcrun lipo -create "$@" -output "${output}"
fi
