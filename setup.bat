@echo off

set ERROR=0

if not defined VULKAN_SDK (
	echo Could not find the Vulkan SDK installation.
	set ERROR=1
	goto post_shaderc_copy
)

mkdir vendor\shaderc\libs
copy /b %VULKAN_SDK%\Lib\shaderc_combined.lib vendor\shaderc\libs\shaderc_combined.lib

:post_shaderc_copy

if %ERROR% equ 1 (
	echo The setup has failed.
) else (
	echo The setup has completed successfully.
)
