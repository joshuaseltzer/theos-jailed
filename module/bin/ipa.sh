#!/bin/bash

source "$STAGE"

# https://github.com/fastlane/fastlane/blob/cb3e7aae706af6ff330838677562fe3584afc195/sigh/lib/assets/resign.sh#L181
# list of plist keys used for reference to and from nested apps and extensions
NESTED_APP_REFERENCE_KEYS=(":WKCompanionAppBundleIdentifier" ":NSExtension:NSExtensionAttributes:WKAppBundleIdentifier")

function copy { 
	rsync -a "$@" --exclude _MTN --exclude .git --exclude .svn --exclude .DS_Store --exclude ._*
}

if [[ -d $RESOURCES_DIR ]]; then
	log 2 "Copying resources"
	copy "$RESOURCES_DIR"/ "$appdir" --exclude "/Info.plist"
fi

function change_bundle_id {
	info_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1")
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID${info_bundle_id#$app_bundle_id}" "$1"

	# https://github.com/fastlane/fastlane/blob/cb3e7aae706af6ff330838677562fe3584afc195/sigh/lib/assets/resign.sh#L582
	# check for nested identifiers that might also need updated (e.g. Watch app / extension bundle IDs)
	for key in "${NESTED_APP_REFERENCE_KEYS[@]}"; do
		# check if Info.plist contains a nested app reference key
		ref_bundle_id=$(PlistBuddy -c "Print ${key}" "$1" 2>/dev/null)
		if [ -n "$ref_bundle_id" ]; then
			/usr/libexec/PlistBuddy -c "Set ${key} $BUNDLE_ID${ref_bundle_id#$app_bundle_id}" "$1"
		fi
	done
}

if [[ -n $BUNDLE_ID ]]; then
	log 2 "Setting bundle ID for all Info.plist files"
	export -f change_bundle_id
	export app_bundle_id
	find "$appdir" -type f -name "Info.plist" -print0 | xargs -I {} -0 bash -c "change_bundle_id '{}'"
fi

if [[ -n $DISPLAY_NAME ]]; then
	log 2 "Setting display name"
	/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string" "$app_info_plist" 
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$app_info_plist" 
fi

if [[ -f $RESOURCES_DIR/Info.plist ]]; then
	log 2 "Merging Info.plist"
	copy "$RESOURCES_DIR/Info.plist" "$STAGING_DIR"
	/usr/libexec/PlistBuddy -c "Merge $app_info_plist" "$STAGING_DIR/Info.plist"
	mv "$STAGING_DIR/Info.plist" "$appdir"
fi

log 2 "Copying dependencies"
inject_files=("$DYLIB" $INJECT_DYLIBS)
copy_files=($EMBED_FRAMEWORKS $EMBED_LIBRARIES)
[[ $USE_CYCRIPT = 1 ]] && inject_files+=("$CYCRIPT")
[[ $USE_FLEX = 1 ]] && inject_files+=("$FLEX")
[[ $USE_OVERLAY = 1 ]] && inject_files+=("$OVERLAY")
[[ $GENERATOR == "MobileSubstrate" ]] && copy_files+=("$SUBSTRATE")

full_copy_path="$appdir/$COPY_PATH"
mkdir -p "$full_copy_path"
for file in "${inject_files[@]}" "${copy_files[@]}"; do
	copy "$file" "$full_copy_path"
done

log 3 "Injecting dependencies"
app_binary="$appdir/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app_info_plist")"

install_name_tool -add_rpath "@executable_path/$COPY_PATH" "$app_binary"
for file in "${inject_files[@]}"; do
	filename=$(basename "$file")
	install_name_tool -change "$STUB_SUBSTRATE_INSTALL_PATH" "$SUBSTRATE_INSTALL_PATH" "$full_copy_path/$filename"
	if [[ $_FAKESIGN_IPA = 1 ]]; then
		"$INSERT_DYLIB" --inplace --no-strip-codesig "@rpath/$(basename "$file")" "$app_binary"
	else
		"$INSERT_DYLIB" --inplace --all-yes "@rpath/$(basename "$file")" "$app_binary"
	fi

	if [[ $? != 0 ]]; then
		error "Failed to inject $filename into $app"
	fi
done

chmod +x "$app_binary"

if [[ $_FAKESIGN_IPA = 1 ]]; then
	log 4 "Fakesigning $app"
	ldid -s "$appdir"
elif [[ $_CODESIGN_IPA = 1 ]]; then
	log 4 "Signing $app"

	if [[ ! -r $PROFILE ]]; then
		bundleprofile=$(grep -Fl "<string>iOS Team Provisioning Profile: $PROFILE</string>" ~/Library/MobileDevice/Provisioning\ Profiles/* | head -1)
		if [[ ! -r $bundleprofile ]]; then
			error "Could not find profile '$PROFILE'"
		fi
		PROFILE="$bundleprofile"
	fi

	if [[ $_EMBED_PROFILE = 1 ]]; then
		copy "$PROFILE" "$appdir/embedded.mobileprovision"
	fi

	security cms -Di "$PROFILE" -o "$PROFILE_FILE"
	if [[ $? != 0 ]]; then
		error "Failed to generate entitlements"
	fi

	if [[ -n $DEV_CERT_NAME ]]; then
		codesign_name=$(security find-certificate -c "$DEV_CERT_NAME" login.keychain | grep alis | cut -f4 -d\" | cut -f1 -d\")
	else
		# http://maniak-dobrii.com/extracting-stuff-from-provisioning-profile/
		codesign_name=$(/usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:0" "$PROFILE_FILE" | openssl x509 -noout -inform DER -subject | sed -E 's/.*CN[[:space:]]*=[[:space:]]*([^,]+).*/\1/')
	fi
	if [[ -z $codesign_name ]]; then
		error "Failed to get codesign name"
	fi

	/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$PROFILE_FILE" > "$ENTITLEMENTS"
	if [[ $? != 0 ]]; then
		error "Failed to generate entitlements"
	fi

	if [[ $_FIX_ENTITLEMENTS = 1 ]]; then
		log 4 "Fixing entitlements"

		# https://github.com/dayanch96/iSigner/blob/main/resign.sh#L24
		# fix iCloud environment (force it to 'Production')
		/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-container-environment" "$ENTITLEMENTS" 2>/dev/null
		/usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Production" "$ENTITLEMENTS"

		# fix iCloud services (force it to array with 'CloudKit')
		/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-services" "$ENTITLEMENTS" 2>/dev/null
		/usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-services array" "$ENTITLEMENTS"
		/usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-services:0 string CloudKit" "$ENTITLEMENTS"
	fi
	
	find "$appdir" \( -name "*.framework" -or -name "*.dylib" -or -name "*.appex" \) -not -path "*.framework/*" -print0 | xargs -0 codesign --entitlements "$ENTITLEMENTS" -fs "$codesign_name"
	if [[ $? != 0 ]]; then
		error "Codesign failed"
	fi
	
	codesign -fs "$codesign_name" --entitlements "$ENTITLEMENTS" "$appdir"
	if [[ $? != 0 ]]; then
		error "Failed to sign $app"
	fi
fi

cd "$STAGING_DIR"
if [[ "${OUTPUT_NAME##*.}" = "app" ]]; then
	cp -a "$appdir" "$PACKAGES_DIR/$OUTPUT_NAME"
else
	log 4 "Repacking $app"
	zip -yqr$COMPRESSION "$OUTPUT_NAME" Payload/
	if [[ $? != 0 ]]; then
		error "Failed to repack $app"
	fi
	rm -rf "$PACKAGES_DIR"/*.ipa "$PACKAGES_DIR"/*.app
	mv "$OUTPUT_NAME" "$PACKAGES_DIR/"
fi
