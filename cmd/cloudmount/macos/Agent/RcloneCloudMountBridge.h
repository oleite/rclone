#ifndef RCLONE_CLOUDMOUNT_BRIDGE_H
#define RCLONE_CLOUDMOUNT_BRIDGE_H

char *RcloneCloudMountList(const char *remote, const char *directory);
char *RcloneCloudMountStat(const char *remote, const char *path, int isDirectory);
char *RcloneCloudMountFetch(const char *remote, const char *path, const char *destinationPath);
void RcloneCloudMountFreeString(char *value);

#endif
