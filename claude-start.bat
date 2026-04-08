@echo off
echo.
echo  Projects:
echo  ---------
setlocal enabledelayedexpansion
set i=0

for /d %%D in ("%~dp0*") do (
    if exist "%%D\.git" (
        set /a i+=1
        set "proj[!i!]=%%D"
        echo   !i!. %%~nxD
    ) else (
        for /d %%S in ("%%D\*") do (
            if exist "%%S\.git" (
                set /a i+=1
                set "proj[!i!]=%%S"
                echo   !i!. %%~nxD/%%~nxS
            )
        )
    )
)

echo.
set /p choice="Pick a project: "
cd /d "!proj[%choice%]!"
claude
