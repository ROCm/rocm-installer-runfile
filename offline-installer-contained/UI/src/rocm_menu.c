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
#include "rocm_menu.h"
#include "help_menu.h"
#include "utils.h"
#include <stdlib.h>
#include <string.h>


/***************** ROCm Main Menu Setup *****************/
char *rocmMenuMainOp[] = {
    "Install ROCm",
    "   ROCm Component List",
    "   ROCm Install Path",
    SKIPPABLE_MENU_ITEM,
    "Uninstall ROCm",
    SKIPPABLE_MENU_ITEM,
    "<HELP>",
    "<DONE>",
    (char*)NULL,
};

char *rocmMenuMainDesc[] = {
    "Enable/Disable ROCm install.  Enabling will search for ROCm.",
    "Display a list of ROCm components included in the installation.",
    "Set ROCm Install Directory.",
    SKIPPABLE_MENU_ITEM,
    "Uninstall runfile ROCm.",
    SKIPPABLE_MENU_ITEM,
    DEFAULT_VERBOSE_HELP_WINDOW_MSG,
    "Exit to Main Menu",
    (char*)NULL,
};

MENU_PROP rocmMenuMainProps  = {
    .pMenuTitle = "ROCm Options",
    .pMenuControlMsg = "<DONE> to exit",
    .numLines = ARRAY_SIZE(rocmMenuMainOp) - 1,
    .numCols = MAX_MENU_ITEM_COLS, 
    .starty = ROCM_MENU_ITEM_START_Y, 
    .startx = ROCM_MENU_ITEM_START_X, 
    .numItems = ARRAY_SIZE(rocmMenuMainOp)
};

ITEMLIST_PARAMS rocmMenuMainItems = {
    .numItems           = (ARRAY_SIZE(rocmMenuMainOp)),
    .pItemListTitle     = "Settings:",
    .pItemListChoices   = rocmMenuMainOp,
    .pItemListDesp      = rocmMenuMainDesc
};

/***************** ROCm Help Sub-Menu Setup *****************/
char *rocmHelpMenuOp[] = {
    "Install ROCm",
    "ROCm Component List",
    "ROCm Install Path",
    "Uninstall ROCm",
    SKIPPABLE_MENU_ITEM,
    (char*)NULL,
};

char *rocmHelpMenuDesc[] = {
    "Enable/Disable the inclusion of ROCm components        as part of the installation.",
    "List all ROCm components included                      in the ROCm install.",
    "The location on the system where ROCm components       will be installed.",
    "Uninstall runfile-based ROCm installation.             This is not available for package installed ROCm.",
    " ",
    (char*)NULL,
};

MENU_PROP rocmHelpMenuProps  = {
    .pMenuTitle = "ROCm Options Help",
    .pMenuControlMsg = DEFAULT_VERBOSE_HELP_CONTROL_MSG,
    .numLines = 0,
    .numCols = MAX_MENU_ITEM_COLS, 
    .starty = ROCM_MENU_ITEM_START_Y, 
    .startx = ROCM_MENU_ITEM_START_X, 
    .numItems = 0
};

ITEMLIST_PARAMS rocmHelpMenuItems = {
    .numItems           = 0,
    .pItemListTitle     = "ROCm Install Settings Description:",
    .pItemListChoices   = NULL,
    .pItemListDesp      = NULL
};

void process_rocm_menu();
void process_rocm_uninstall_menu();
void process_rocm_uninstall_item();
void update_rocm_uinstall_menu();

// forms
void process_rocm_menu_form(MENU_DATA *pMenuData);

// menu draw/config
void rocm_menu_toggle_grey_items(bool enable);
void rocm_menu_draw();

// sub-menus
void create_rocm_help_menu_window();

void create_rocm_uninstall_window(WINDOW *pMenuWindow, OFFLINE_INSTALL_CONFIG *pConfig);
void destroy_rocm_uninstall_menu_window();
void do_rocm_uninstall_menu();


// ROCM Uninstall Menu
uint8_t rocm_paths_uninstall_state[MAX_PATHS] = {0};
char *rocm_paths_items[MAX_PATHS + 4] = {0};
char *rocm_paths_item_desc[MAX_PATHS + 4] = {0};

MENU_PROP rocmPathsProps = {0};
ITEMLIST_PARAMS rocmPathsItems = {0};

// ROCm menus
MENU_DATA menuROCm = {0};
MENU_DATA menuROCmUninstall = {0};
bool gRocmStatusCheck = false;


/**************** ROCm MENU **********************************************************************************/

void create_rocm_menu_window(WINDOW *pMenuWindow, OFFLINE_INSTALL_CONFIG *pConfig)
{
    ROCM_MENU_CONFIG *pRocmConfig = &pConfig->rocm_config;

    // Create the ROCm options menu
    create_menu(&menuROCm, pMenuWindow, &rocmMenuMainProps, &rocmMenuMainItems, pConfig);

    // Create verbose help menu
    menuROCm.pHelpMenu = calloc(1, sizeof(MENU_DATA));
    if (menuROCm.pHelpMenu)
    {
        create_rocm_help_menu_window();
    }

    // Set pointer to draw menu function when window is resized
    menuROCm.drawMenuFunc = rocm_menu_draw;

    // Set user pointer for 'ENTER' events
    set_menu_userptr(menuROCm.pMenu, process_rocm_menu);

    // Initialize the menu config settings
    sprintf(pRocmConfig->rocm_install_path, "%s", ROCM_MENU_DEFAULT_INSTALL_PATH);

    // Initialize the rocm config
    pRocmConfig->install_rocm = false;      // disable rocm install by default
    pRocmConfig->is_rocm_path_valid = true; // default path "/" is valid

    // set items to non-selectable
    set_menu_grey(menuROCm.pMenu, COLOR_PAIR(5));
    menu_set_item_select(&menuROCm, menuROCm.itemList[0].numItems - 4, false);  // space before done
    rocm_menu_toggle_grey_items(false);
    
    // create a form for user input
    create_form(&menuROCm, pMenuWindow, ROCM_MENU_NUM_FORM_FIELDS, ROCM_MENU_FORM_FIELD_WIDTH, ROCM_MENU_FORM_FIELD_HEIGHT, 
            ROCM_MENU_FORM_ROW, ROCM_MENU_FORM_COL);

    strcpy(menuROCm.pFormList.formControlMsg, DEFAULT_FORM_CONTROL_MSG);

    // Initialize form field names and associated config settings
    set_form_userptr(menuROCm.pFormList.pForm, process_rocm_menu_form);
    set_field_buffer(menuROCm.pFormList.field[0], 0, ROCM_MENU_DEFAULT_INSTALL_PATH);
}

void destroy_rocm_menu_window()
{
    destroy_help_menu(menuROCm.pHelpMenu);
    destroy_menu(&menuROCmUninstall);
    destroy_menu(&menuROCm);
}

void rocm_menu_toggle_grey_items(bool enable)
{
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCm.pConfig)->rocm_config;

    if (enable)
    {
        // enable all rocm option fields
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_INSTALL_ROCM_INDEX, true);
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_LIST_INDEX, true);
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_ROCM_PATH_INDEX, true);

        // enable uninstall if rocm is currently installed
        if (pRocmConfig->is_rocm_installed)
        {
            menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_UNINSTALL_ROCM_INDEX, true);
        }
    }
    else
    {
        // disable all rocm option fields
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_INSTALL_ROCM_INDEX, false);
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_LIST_INDEX, false);
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_ROCM_PATH_INDEX, false);
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_UNINSTALL_ROCM_INDEX, false);
    }
}

int find_rocm_with_progress() 
{
    int height = 3; 
    int width = PROGRESS_BAR_WIDTH + 5;
    int start_y = WIN_NUM_LINES;
    int start_x = WIN_START_X + 1;

    int status;
    int pipefd[2];
    int fd = -1;

    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCm.pConfig)->rocm_config;

    // clear the current paths
    memset(pRocmConfig->rocm_paths, '\0', sizeof(pRocmConfig->rocm_paths));
    pRocmConfig->rocm_count = 0;

    if (pipe(pipefd) == -1) 
    {
        perror("pipe");
        return -1;
    }

    WINDOW *progress_win = newwin(height, width, start_y, start_x);
    wrefresh(progress_win);

    pid_t pid = fork();
    if (pid == 0) 
    {
        // Child

        close(pipefd[0]); // Close unused read end
        
        fd = open("/dev/null", O_WRONLY);
        if (fd == -1)
        {
            exit(1);
        }

        dup2(fd, 1);

        // Call the function
        status = find_rocm_installed(pRocmConfig->rocm_paths, &(pRocmConfig->rocm_count));

        // Write the result to the pipe
        write(pipefd[1], &pRocmConfig->rocm_count, sizeof(pRocmConfig->rocm_count));
        for (int i = 0; i < pRocmConfig->rocm_count; i++) 
        {
            write(pipefd[1], pRocmConfig->rocm_paths[i], sizeof(pRocmConfig->rocm_paths[i]));
        }

        close(pipefd[1]); // Close write end

        // exit with the function's return status
        exit(status);
    } 
    else if (pid > 0) 
    {
        // Parent
        
        close(pipefd[1]); // Close unused write end

        status = wait_with_progress_bar(pid, 5000, 0);

        // Read the result from the pipe
        read(pipefd[0], &pRocmConfig->rocm_count, sizeof(pRocmConfig->rocm_count));
        for (int i = 0; i < pRocmConfig->rocm_count; i++) 
        {
            read(pipefd[0], pRocmConfig->rocm_paths[i], sizeof(pRocmConfig->rocm_paths[i]));
        }

        close(pipefd[0]); // Close read end
    } 
    else
    {
        // Fork failed
        endwin();
        perror("fork");

        exit(1);
    }

    // close any open file descriptors
    if (fd >= 0)
    {
        close(fd);
    }

    delwin(progress_win);

    return status;
}

void check_rocm_install_status()
{
    OFFLINE_INSTALL_CONFIG *pConfig = menuROCm.pConfig;
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCm.pConfig)->rocm_config;

    gRocmStatusCheck = true;

    // check if rocm is installed via package management
    if (is_rocm_pkg_installed(pConfig->distroType) > 0)
    {
        pRocmConfig->rocm_install_type = eINSTALL_PACKAGE;
        pRocmConfig->is_rocm_installed = true;
    }
    else
    {
        // check for a runfile install
        if (find_rocm_with_progress() == 0)
        {
            pRocmConfig->rocm_install_type = eINSTALL_RUNFILE;
            pRocmConfig->is_rocm_installed = true;

            // update the uninstall menu
            update_rocm_uinstall_menu();
        }
        else
        {
            // no ROCm install
            pRocmConfig->rocm_install_type = eINSTALL_NONE;
            pRocmConfig->is_rocm_installed = false;
        }
    }

    // grey-out the ROCm install ops depending if the ROCm is installed or not
    menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_INSTALL_ROCM_INDEX, !pRocmConfig->is_rocm_installed);

    // allow uninstall for runfile only
    if (pRocmConfig->rocm_install_type == eINSTALL_RUNFILE)
    {
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_UNINSTALL_ROCM_INDEX, pRocmConfig->is_rocm_installed);
    }
    else
    {
        menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_UNINSTALL_ROCM_INDEX, false);
    }
}

void rocm_status_draw()
{
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCm.pConfig)->rocm_config;

    // check for the ROCm status and draw
    if (pRocmConfig->rocm_install_type == 0)
    {
        print_menu_msg(&menuROCm, COLOR_PAIR(4), "ROCm not installed.");
    }
    else if (pRocmConfig->rocm_install_type == eINSTALL_PACKAGE)
    {
        print_menu_err_msg(&menuROCm, "ROCm package manager install found. Uninstall required.");
    }
    else if (pRocmConfig->rocm_install_type == eINSTALL_RUNFILE)
    {
        print_menu_warning_msg(&menuROCm, "ROCm runfile install found.  Uninstall optional.");
    }
    else
    {
        print_menu_err_msg(&menuROCm, "ROCm installation status unknown.");
    }
}

void rocm_menu_draw()
{
    WINDOW *pMenuWindow = menuROCm.pMenuWindow;
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCm.pConfig)->rocm_config;

    char drawName[DEFAULT_CHAR_SIZE];

    if (!gRocmStatusCheck)
    {
        mvwprintw(pMenuWindow, ROCM_MENU_ROCM_STATUS_ROW, ROCM_MENU_ROCM_STATUS_COL, "%s", "<Select to Search>");
    }
    else
    {
        mvwprintw(pMenuWindow, ROCM_MENU_ROCM_STATUS_ROW, ROCM_MENU_ROCM_STATUS_COL, "%s", "                  ");
    }

    menu_info_draw_bool(&menuROCm, ROCM_MENU_ITEM_INSTALL_ROCM_ROW, ROCM_MENU_FORM_COL, pRocmConfig->install_rocm);
    
    field_trim(pRocmConfig->rocm_install_path, drawName, ROCM_MENU_FORM_FIELD_WIDTH);
    mvwprintw(pMenuWindow, ROCM_MENU_FORM_ROW,  ROCM_MENU_FORM_COL, "%s", drawName);

    menu_draw(&menuROCm);
}

void do_rocm_menu()
{  
    MENU *pMenu = menuROCm.pMenu;

    wclear(menuROCm.pMenuWindow);

    // draw the ROCm menu contents
    rocm_menu_draw(&menuROCm);

    // ROCm menu loop
    menu_loop(&menuROCm);

    unpost_menu(pMenu);
}

// process "ENTER" key events from the ROCm main menu
void process_rocm_menu()
{
    MENU *pMenu = menuROCm.pMenu;
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCm.pConfig)->rocm_config;

    ITEM *pCurrentItem = current_item(pMenu);

    int index = item_index(pCurrentItem);

    DEBUG_UI_MSG(&menuROCm, "ROCM Menu: %d, itemlist %d", index, menuROCm.curItemListIndex);

    if (index == ROCM_MENU_ITEM_INSTALL_ROCM_INDEX)
    {
        // check the rocm status
        if (!gRocmStatusCheck) check_rocm_install_status();
        rocm_status_draw();

        // allow toggle of rocm install if rocm is not currently installed or is runfile installed
        if (!pRocmConfig->is_rocm_installed || pRocmConfig->rocm_install_type == eINSTALL_RUNFILE)
        {
            pRocmConfig->install_rocm = !pRocmConfig->install_rocm;

            rocm_menu_toggle_grey_items(pRocmConfig->install_rocm);
            menu_info_draw_bool(&menuROCm, ROCM_MENU_ITEM_INSTALL_ROCM_ROW, ROCM_MENU_FORM_COL, pRocmConfig->install_rocm);
        }
        
        if (!pRocmConfig->install_rocm)
        {
            gRocmStatusCheck = false; // reset the rocm install check if install rocm toggled off
            
            if (pRocmConfig->rocm_install_type == eINSTALL_NONE)
            {
                clear_menu_msg(&menuROCm);
            }
        }
    }
    else if (index == ROCM_MENU_ITEM_LIST_INDEX)
    {
        if (pRocmConfig->install_rocm)
        {
            display_scroll_window("Component List:", " ROCm Components:", "./component-rocm/components.txt", NULL);
        }
    }
    else if (index == ROCM_MENU_ITEM_ROCM_PATH_INDEX)
    {
        FORM *pForm = menuROCm.pFormList.pForm;
        if (pForm && (pRocmConfig->install_rocm))
        {
            // switch to the form for ROCm build number
            unpost_menu(pMenu);

            void (*ptrFormFnc)(MENU_DATA*);

            ptrFormFnc = form_userptr(pForm);
            if (NULL != ptrFormFnc)
            {
                ptrFormFnc((MENU_DATA*)&menuROCm);
            }
            else
            {
                DEBUG_UI_MSG(&menuROCm, "No user ptr for form");
            }
        }
    }
    else if (index == ROCM_MENU_ITEM_UNINSTALL_ROCM_INDEX)
    {
        // only uninstall if ROCm is installed
        if (pRocmConfig->is_rocm_installed && (pRocmConfig->rocm_install_type == eINSTALL_RUNFILE))
        {
            clear_menu_msg(&menuROCm);

            unpost_menu(pMenu);
            do_rocm_uninstall_menu();
        }
    }
    else
    {
        DEBUG_UI_MSG(&menuROCm, "Unknown item index");
    }

    rocm_menu_draw();
}

// process "ENTER" key event from menu if form userptr set
void process_rocm_menu_form(MENU_DATA *pMenuData)
{
    MENU *pMenu = pMenuData->pMenu;
    FORM *pForm = pMenuData->pFormList.pForm;

    ROCM_MENU_CONFIG *pRocmConfig = &(pMenuData->pConfig)->rocm_config;

    post_form(pForm);
    post_menu(pMenu);

    rocm_menu_draw(pMenuData);

    print_form_control_msg(pMenuData);

    // Switch to form control loop for entering data into given form field
    form_loop(pMenuData, false);

    unpost_form(pForm);
    unpost_menu(pMenu);

    // store the ROCm install target path on exit
    strcpy(pRocmConfig->rocm_install_path, field_buffer(pForm->field[0], 0));

    if (check_path_exists(pRocmConfig->rocm_install_path, MAX_FORM_FIELD_WIDTH) == 0)
    {
        print_menu_msg(pMenuData, COLOR_PAIR(4), "ROCm Install Path Valid");
        pRocmConfig->is_rocm_path_valid = true;
    }
    else
    {
        print_menu_err_msg(pMenuData, "ROCm Install Path Invalid");
        pRocmConfig->is_rocm_path_valid = false;
    }

    DEBUG_UI_MSG(pMenuData, "ROCM path =%s", pRocmConfig->rocm_install_path);
}

/**************** ROCM HELP MENU *****************************************************************************/

void create_rocm_help_menu_window()
{
    MENU_DATA *pMenuData = menuROCm.pHelpMenu;
    WINDOW *pMenuWindow = menuROCm.pMenuWindow;

    // Create menu window w/ border and title
    create_menu(pMenuData, pMenuWindow, &rocmHelpMenuProps, &rocmHelpMenuItems, NULL);
    menu_opts_off(pMenuData->pMenu, O_SHOWDESC);

    // Create form that displays verbose help menu
    create_help_form(pMenuData, pMenuWindow, ROCM_HELP_MENU_DESC_STARTX, ROCM_HELP_MENU_DESC_STARTY, HELP_MENU_DESC_WIDTH, HELP_MENU_OP_STARTX, HELP_MENU_OP_WIDTH, rocmHelpMenuOp, rocmHelpMenuDesc); 
}

/**************** ROCM Uninstall MENU **************************************************************************/
void rocm_uninstall_menu_draw()
{
    WINDOW *pWin = menuROCmUninstall.pMenuWindow;
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCmUninstall.pConfig)->rocm_config;
    
    menu_draw(&menuROCmUninstall);

    wattron(pWin, COLOR_PAIR(9) | A_BOLD);
    mvwprintw(pWin, 3, 27, "%d", pRocmConfig->rocm_count);
    wattroff(pWin, COLOR_PAIR(9) | A_BOLD);

    ITEM **items = menu_items(menuROCmUninstall.pMenu);
    if(item_value(items[menuROCmUninstall.curItemSelection]) == TRUE)
    {
        print_menu_msg(&menuROCmUninstall, COLOR_PAIR(3), "Uninstall: %s", pRocmConfig->rocm_paths[menuROCmUninstall.curItemSelection]);
    }
}

void do_rocm_uninstall_menu()
{
    rocm_uninstall_menu_draw();
    
    menu_loop(&menuROCmUninstall);

    wclear(menuROCmUninstall.pMenuWindow);

    unpost_menu(menuROCmUninstall.pMenu);
}

void create_rocm_uninstall_window(WINDOW *pMenuWindow, OFFLINE_INSTALL_CONFIG *pConfig)
{
    ROCM_MENU_CONFIG *pRocmConfig = &pConfig->rocm_config;
    
    // set the path pointers to the found rocm paths
    if (pRocmConfig->rocm_count != 0) 
    {
        int i;
        for (i = 0; i < pRocmConfig->rocm_count; i++) 
        {
            rocm_paths_items[i] = pRocmConfig->rocm_paths[i];
            rocm_paths_item_desc[i] = pRocmConfig->rocm_paths[i];
        }

        rocm_paths_items[i] = " ";
        rocm_paths_item_desc[i++] = " ";

        rocm_paths_items[i] = "<UNINSTALL>";
        rocm_paths_item_desc[i++] = "Uninstall selected ROCm installation.";

        rocm_paths_items[i] = "<DONE>";
        rocm_paths_item_desc[i++] = " Exit to ROCm Options Menu";

        int numItems = i + 1;

        rocmPathsProps = (MENU_PROP) {
            .pMenuTitle = "ROCm Uninstall",
            .pMenuControlMsg = "<DONE> to exit : Space key to select/unselect uninstall location",
            .numLines = numItems - 1,
            .numCols = MAX_MENU_ITEM_COLS,
            .starty = ROCM_MENU_ITEM_START_Y,
            .startx = 4,
            .numItems = numItems
        };

        rocmPathsItems = (ITEMLIST_PARAMS) {
            .numItems           = numItems,
            .pItemListTitle     = "ROCm Install Locations:",
            .pItemListChoices   = rocm_paths_items,
            .pItemListDesp      = rocm_paths_item_desc
        };

        // Create the ROCm Sub-Menu
        create_menu(&menuROCmUninstall, pMenuWindow, &rocmPathsProps, &rocmPathsItems, pConfig);
        
        menuROCmUninstall.enableMultiSelection = false;   // single selection
        menuROCmUninstall.isMenuItemsSelectable = true;   // items are selectable

        // Make the menu multi valued
        menu_opts_off(menuROCmUninstall.pMenu, O_ONEVALUE);

        // set items to non-selectable for the menu
        set_menu_fore(menuROCmUninstall.pMenu, COLOR_PAIR(3) | A_BOLD); // white/bold

        // Disable items from being selectable
        set_menu_grey(menuROCmUninstall.pMenu, COLOR_PAIR(5));

        // set item userptrs
        ITEM **items = menu_items(menuROCmUninstall.pMenu);
        set_item_userptr(items[numItems - 2], process_rocm_uninstall_item);    // DONE
        set_item_userptr(items[numItems - 3], process_rocm_uninstall_item);    // UNINSTALL

        for (i = 0; i < pRocmConfig->rocm_count; i++)
        {
            set_item_userptr(items[i], process_rocm_uninstall_item);
        }

        // set the uninstall state / deselect
        for (i = 0; i < pRocmConfig->rocm_count; i++)
        {
            if (rocm_paths_uninstall_state[i] == 1)
            {
                menu_set_item_select(&menuROCmUninstall, i, false);
            }
        }
    }

    // Set pointer to draw menu function when window is resized
    menuROCmUninstall.drawMenuFunc = rocm_uninstall_menu_draw;

    // Set user pointer for 'ENTER' events
    set_menu_userptr(menuROCmUninstall.pMenu, process_rocm_uninstall_menu);
}

void destroy_rocm_uninstall_menu_window()
{
    destroy_menu(&menuROCmUninstall);

    memset(&menuROCmUninstall, 0, sizeof(menuROCmUninstall));
    memset(rocm_paths_items, 0, sizeof(rocm_paths_items));
    memset(rocm_paths_item_desc, 0, sizeof(rocm_paths_item_desc));
    memset(rocm_paths_uninstall_state, 0, sizeof(rocm_paths_uninstall_state));
}

void update_rocm_uinstall_menu()
{
    destroy_rocm_uninstall_menu_window();

    create_rocm_uninstall_window(menuROCm.pMenuWindow, menuROCm.pConfig);
}

void uninstall_rocm_paths()
{
    int i;

    MENU *pMenu = menuROCmUninstall.pMenu;
    WINDOW *pWin = menuROCmUninstall.pMenuWindow;
    ITEM **items = menuROCmUninstall.itemList[0].items;

    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCmUninstall.pConfig)->rocm_config;

    char target[LARGE_CHAR_SIZE];
    size_t len;

    int uninstall_index = -1;

    memset(target, '\0', LARGE_CHAR_SIZE);
    strcat(target, "target=");

    for(i = 0; i < item_count(pMenu); ++i)
    {
        if(item_value(items[i]) == TRUE)
        {
            if (strncmp(pRocmConfig->rocm_paths[i], "/opt/rocm", 9) == 0) 
            {
               strcat(target, "/");
               uninstall_index = i;
               break;
            }
            else 
            {
                char *pos = strstr(pRocmConfig->rocm_paths[i], "/opt");
                if (pos) 
                {
                    len = pos - pRocmConfig->rocm_paths[i];
                    strncat(target, pRocmConfig->rocm_paths[i], len);
                    uninstall_index = i;
                    break;
                }
            }
        }
    }
    
    // uninstall for specific path index
    if (uninstall_index >= 0)
    {
        strcat(target, " uninstall-rocm");

        // execute the ROCm uninstall command
        if (execute_cmd("./rocm-installer.sh", target, pWin) == 0)
        {
            print_menu_msg(&menuROCm, COLOR_PAIR(4), "Uninstall Complete.");

            // update the state for the uninstalled item
            menu_set_item_select(&menuROCmUninstall, uninstall_index, false);
            delete_menu_item_selection_mark(&menuROCmUninstall, items[uninstall_index]);

            rocm_paths_uninstall_state[uninstall_index] = 1;
            pRocmConfig->rocm_count--;

            // if no rocm installs, disable the uninstall item on the rocm menu
            if (pRocmConfig->rocm_count == 0)
            {
                menu_set_item_select(&menuROCm, ROCM_MENU_ITEM_UNINSTALL_ROCM_INDEX, false);
                pRocmConfig->is_rocm_installed = false;
                pRocmConfig->rocm_install_type = eINSTALL_NONE;
            }
        }
        else
        {
            print_menu_err_msg(&menuROCm, "Uninstall Failed.");
        }

        wrefresh(pWin);
    }
}

// rocm uninstall item processing
void process_rocm_uninstall_item()
{
    MENU *pMenu = menuROCmUninstall.pMenu;
    ITEM **items = menu_items(pMenu);
    int i;

    DEBUG_UI_MSG(&menuROCmUninstall, "item userptr: item index %d : count %d", item_index(pCurrentItem), item_count(pMenu));

    // white/bold
    set_menu_fore(menuROCmUninstall.pMenu, COLOR_PAIR(3) | A_BOLD);

    // set any selected item to the select colour (cyan)
    for(i = 0; i < item_count(pMenu); ++i)
    {
        if(item_value(items[i]) == TRUE)
        {
            set_menu_fore(menuROCmUninstall.pMenu, COLOR_PAIR(2) | A_BOLD); 
        }
    }
}

// process "ENTER" key events from the ROCm main menu
void process_rocm_uninstall_menu()
{
    MENU *pMenu = menuROCmUninstall.pMenu;
    ROCM_MENU_CONFIG *pRocmConfig = &(menuROCmUninstall.pConfig)->rocm_config;

    ITEM *pCurrentItem = current_item(pMenu);

    int index = item_index(pCurrentItem);
    int uninstall_index = item_count(pMenu) - 2;

    DEBUG_UI_MSG(&menuROCmUninstall, "ROCM Uninstall Menu: %d, itemlist %d", index, menuROCmUninstall.curItemListIndex);

    if (index == uninstall_index)
    {
        if (pRocmConfig->rocm_count > 0)
        {
            uninstall_rocm_paths();
        }

        if (pRocmConfig->rocm_count == 0)
        {
            menu_set_item_select(&menuROCmUninstall, uninstall_index, false);
        }

        DEBUG_UI_MSG(&menuROCmUninstall, "uninstall_index %d", uninstall_index);
    }
    else
    {
        DEBUG_UI_MSG(&menuROCmUninstall, "Unknown item index %d", item_count(pMenu));
    }

    rocm_uninstall_menu_draw();
}
