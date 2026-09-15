#ifndef RCLONE_CLOUDMOUNT_BRIDGE_H
#define RCLONE_CLOUDMOUNT_BRIDGE_H

char *RcloneCloudMountList(const char *remote, const char *directory);
char *RcloneCloudMountStat(const char *remote, const char *path, int isDirectory);
/* FetchFD duplicates fd and owns/closes only its duplicate. */
char *RcloneCloudMountFetchFD(const char *remote, const char *path, int fd);
void RcloneCloudMountFreeString(char *value);

#endif
