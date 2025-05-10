REM Odin Freetype bindings ---------------------------------------------------

git fetch odin-freetype main
git subtree pull --prefix vendor/freetype odin-freetype main --squash

REM Odin ShaderC bindings ----------------------------------------------------

git fetch odin-shaderc master
git subtree pull --prefix vendor/shaderc odin-shaderc master --squash
