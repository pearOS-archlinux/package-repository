all:
	repo-add --verify --sign main.db.tar.gz *.pkg.tar.zst
	git add .
	git commit -m "add packages"
	git push
	sudo pacman -Sy
	sudo pacman-key --refresh-keys 781B8934B6FA055066BE08777AA60E85D37C046B
