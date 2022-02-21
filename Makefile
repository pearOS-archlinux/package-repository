all:
	repo-add --verify --sign main/x86_64/main.db.tar.gz main/x86_64/*.pkg.tar.zst
	git add .
	git commit -m "add packages"
	git push
	sudo pacman -Sy
	sudo pacman-key --refresh-keys 781B8934B6FA055066BE08777AA60E85D37C046B
