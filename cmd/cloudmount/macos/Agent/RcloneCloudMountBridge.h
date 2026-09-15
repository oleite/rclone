#ifndef RCLONE_CLOUDMOUNT_BRIDGE_H
#define RCLONE_CLOUDMOUNT_BRIDGE_H

#include <stdint.h>

char *RcloneCloudMountList(const char *remote, const char *directory);
char *RcloneCloudMountStat(const char *remote, const char *path, int isDirectory);
uint64_t RcloneCloudMountTransferCreate(void);
void RcloneCloudMountTransferCancel(uint64_t transfer);
void RcloneCloudMountTransferRelease(uint64_t transfer);
/* Fetch operations duplicate fd and own/close only their duplicate. */
char *RcloneCloudMountFetchFD(const char *remote, const char *path, int fd, uint64_t transfer);
char *RcloneCloudMountFetchRangeFD(const char *remote, const char *path, int fd, int64_t offset, int64_t length, uint64_t transfer);
void RcloneCloudMountFreeString(char *value);

#endif
