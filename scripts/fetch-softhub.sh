#!/bin/sh
# Downloads Afero's Softhub framework (binary-only, Afero Permissive Binary License; see Vendor/AferoSofthub-LICENSE.txt).
# The Hubspace app uses it to relay commands to bulbs that are only on Bluetooth.
set -eu
COMMIT=40919aef6138165ca3e91bd2697addf3d90563b6
cd "$(dirname "$0")/../Vendor"
[ -d AferoSofthub.xcframework ] && exit 0
curl -fsSL -o AferoSofthub.zip "https://raw.githubusercontent.com/aferodeveloper/AferoIOSSofthub/$COMMIT/AferoSofthub.zip"
unzip -q AferoSofthub.zip
rm AferoSofthub.zip
