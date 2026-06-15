#!/bin/bash
exec Xvfb "${DISPLAY:-:20}" -screen 0 "${DISPLAY_WIDTH:-1920}x${DISPLAY_HEIGHT:-1080}x24" +extension GLX +extension RANDR +extension RENDER -ac
