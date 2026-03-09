.PHONY: apk
apk:
	flutter clean
	flutter pub get
	flutter build apk --release --no-tree-shake-icons