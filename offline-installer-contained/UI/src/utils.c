/* ************************************************************************
 * Copyright (C) 2024-2025 Advanced Micro Devices, Inc. All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell cop-
 * ies of the Software, and to permit persons to whom the Software is furnished
 * to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IM-
 * PLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNE-
 * CTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * ************************************************************************ */
#include "utils.h"

#include <string.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <dirent.h>

int calculate_text_height(char *desc, int width)
{
    int desc_length = strlen(desc);
    int rows_needed = ceil(desc_length/width);
    return rows_needed + 1;
}

int get_char_array_size(char *array[])
{
    // array must have last element defined as NULL
    int size = 0;
    if (array != NULL) 
    {
        while (array[size] != NULL) {
            size++;
        }

    }
    return size;
}

bool is_field_empty(char *text)
{
    int count = strlen(text);
    int i = 0;
   
    while (i < count)
    {
        // When user deletes char(s) from form field, it simply replaces the deleted
        // char w/ the ' ' (space) char. So strlen still returns an incorrect value,
        // even when the string is empty. This is a fix for that.
        if (text[i] != ' ')
        {
            return false;
        }

        i++;
    }

    return true;
}

int get_field_length(char *text, int field_width)
{
    char temp[DEFAULT_CHAR_SIZE];
    int i;

    strcpy(temp, text);

    for (i = 0; i < field_width; i++)
    {
        if ((temp[i] == ' ') || (temp[i] == '\0'))
            break;
    }

    return i;
}

void field_trim(char *src, char *dst, int max)
{
    int field_len = get_field_length(src, max);
    
    memset(dst, '\0', DEFAULT_CHAR_SIZE);
    strncpy(dst, src, (max-3));
    if (field_len > (max -3) )
    {
        strcat(dst, "...");
    }
}

int check_url(char *url) 
{
    char command[DEFAULT_CHAR_SIZE];

    sprintf(command, "wget -q --spider %s", url);
    
    return system(command);
}

int check_path_exists(char *path, int max)
{
    int ret = 0;
    struct stat buffer;

    remove_end_spaces(path, max);

    ret = stat(path, &buffer);

    return ret;
}

void remove_slash(char *str)
{
    int len = strlen(str);

    for (int i = 0; i < len; i++)
    {
        if (str[i] == '/')
        {
            str[i] = '-';
        }
    }
}

void remove_end_spaces(char *str, int max)
{
    int field_len = get_field_length(str, max);

    char temp[DEFAULT_CHAR_SIZE];

    memset(temp, '\0', DEFAULT_CHAR_SIZE);
    strncpy(temp, str, field_len);
    
    strcpy(str, temp);
}

int clear_str(char *str)
{
    if (NULL == str)
    {
        return -1;
    }

    memset(str, '\0', strlen(str));

    return 0;
}

bool is_dir_exist(char *path)
{
    DIR* dir = opendir(path);
    if (dir) 
    {
        /* Directory exists. */
        closedir(dir);
        return true;
    } 
    else 
    {
        return false;
    }

}

int is_rocm_pkg_installed(DISTRO_TYPE distroType) 
{
    int status;
    
    if (distroType == eDISTRO_TYPE_DEB)
    {
        status = system("dpkg -l rocm > /dev/null 2>&1");
    }
    else
    {
        status = system("rpm -q rocm > /dev/null 2>&1");
    }

    if (status == -1) 
    {
        perror("system");
        return 0;
    }

    // return status child process/exit status
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int find_rocm_installed(char fpaths[MAX_PATHS][LARGE_CHAR_SIZE], int *pCount) 
{
    FILE *fp;
    char path[LARGE_CHAR_SIZE];
    int status;

    if (pCount == NULL)
    {
        return -1;
    }

    // Command to find the "version" file in directories containing "opt/rocm/.info"
    // and skip any directory paths containing "rocm-installer"
    const char *command = "find / -type f -path '*/opt/rocm-*/.info/version' ! -path '*/rocm-installer/component-rocm/*' -print 2>/dev/null";

    // Open a pipe to the command
    fp = popen(command, "r");
    if (fp == NULL) 
    {
        perror("popen failed");
        exit(1);
    }

    // Initialize found_count
    *pCount = 0;

    // Read the output of the command
    while (fgets(path, sizeof(path), fp) != NULL) 
    {
        // Remove the newline character from the path
        path[strcspn(path, "\n")] = '\0';

        // Remove the substring ".info/version" from the path
        char *pos = strstr(path, ".info/version");
        if (pos != NULL) 
        {
            *pos = '\0'; // Terminate the string at the start of ".info/version"
        }

        // Save the path to the array
        if (*pCount < MAX_PATHS) 
        {
            strncpy(fpaths[*pCount], path, LARGE_CHAR_SIZE - 1);
            fpaths[*pCount][LARGE_CHAR_SIZE - 1] = '\0';
            (*pCount)++;
        } 
        else 
        {
            fprintf(stderr, "Warning: Maximum number of paths reached. Some paths may not be stored.\n");
            break;
        }
    }

    // Close the command and get the exit status
    status = pclose(fp);
    if (status == -1) 
    {
        perror("pclose");
        return -1;
    }

    // Check if the command was successful
    if (WIFEXITED(status) || WEXITSTATUS(status) == 0) 
    {
        // the command maybe success, check for output
        if (*pCount > 0)
        {
            return 0;
        }
        else
        {
            return -1;
        }
    } 
    else 
    {
        return -1;
    }
}

int is_dkms_pkg_installed(DISTRO_TYPE distroType)
{
    int status;
    
    if (distroType == eDISTRO_TYPE_DEB)
    {
        status = system("apt list --installed 2>&1 | grep dkms  > /dev/null 2>&1");
    }
    else
    {
        status = system("rpm -q dkms > /dev/null 2>&1");
    }

    if (status == -1) 
    {
        perror("system");
        return 0;
    }

    // return status child process/exit status
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int is_amdgpu_dkms_pkg_installed(DISTRO_TYPE distroType) 
{
    int status;
    
    if (distroType == eDISTRO_TYPE_DEB)
    {
        status = system("apt list --installed 2>&1 | grep amdgpu-dkms  > /dev/null 2>&1");
    }
    else
    {
        status = system("rpm -q amdgpu-dkms > /dev/null 2>&1");
    }

    if (status == -1) 
    {
        perror("system");
        return 0;
    }

    // return status child process/exit status
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int check_dkms_status(char *dkms_out, size_t dkms_out_size)
{
    FILE *fp;
    char path[LARGE_CHAR_SIZE];
    int status;

    // Open the command for reading
    fp = popen("dkms status 2>&1", "r");
    if (fp == NULL) 
    {
        perror("popen failed");
        return -1;
    }

    // Read the output a line at a time and store it in dkms_out
    dkms_out[0] = '\0'; // Initialize dkms_out to an empty string
    while (fgets(path, sizeof(path), fp) != NULL) 
    {
        strncat(dkms_out, path, dkms_out_size - strlen(dkms_out) - 1);
    }

    // Close the command and get the exit status
    status = pclose(fp);
    if (status == -1) 
    {
        perror("pclose");
        return -1;
    }

    // Check if the command was successful
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) 
    {
        // the command maybe success, check that dkms provide output
        if (strlen(dkms_out) > 0)
        {
            char *p = strstr(dkms_out, ", x86_64:");
            if (p != NULL)
            {
                *p = '\0';
            }

            return 0;
        }
        return -1;
    } 
    else 
    {
        return -1;
    }
}

int execute_cmd(const char *script, const char *args, WINDOW *pWin)
{
    int ret = 1;

    char cmd[LARGE_CHAR_SIZE];
    clear_str(cmd);

    if (pWin)
    {
        // exit ncurses for the command
        def_prog_mode();
	    endwin();

        sprintf(cmd, "%s %s", script, args);
    }
    else
    {
        sprintf(cmd, "%s %s > /dev/null 2>&1", script, args);
    }

    // execute the command
    ret = system(cmd);
    if ((WEXITSTATUS(ret)) == 0)
    {
        ret = 0;
    }

    if (pWin)
    {
        // return to ncurses
        reset_prog_mode();
        wrefresh(pWin);
    }

    return ret;
}