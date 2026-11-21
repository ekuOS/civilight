# The version denotes the Gentoo dependency interface, not the uutils release.
EAPI=8
DESCRIPTION="Civilight system command names provided by uutils coreutils"
HOMEPAGE="https://github.com/uutils/coreutils"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
IUSE="+xattr"
REQUIRED_USE="xattr"
RDEPEND=">=sys-apps/uutils-coreutils-0.12.0"
DEPEND="${RDEPEND}"
S="${WORKDIR}"

src_install() {
	# Own the standard coreutils paths, but leave hostname, kill, more and
	# uptime with their respective Gentoo packages. Link to ONE binary so
	# dracut does not copy the multicall executable once per command.
	local applet
	local applets=(
		'[' arch b2sum base32 base64 basename basenc cat chgrp chmod chown
		chroot cksum comm cp csplit cut date dd df dir dircolors dirname du
		echo env expand expr factor false fmt fold groups head hostid id
		install join link ln logname ls md5sum mkdir mkfifo mknod mktemp
		mv nice nl nohup nproc numfmt od paste pathchk pinky pr printenv
		printf ptx pwd readlink realpath rm rmdir seq sha1sum sha224sum
		sha256sum sha384sum sha512sum shred shuf sleep sort split stat
		stdbuf stty sum sync tac tail tee test timeout touch tr true
		truncate tsort tty uname unexpand uniq unlink users vdir wc who
		whoami yes
	)
	for applet in "${applets[@]}"; do
		[[ -x "${ESYSROOT}/usr/bin/uu-${applet}" ]] || die "Missing uutils applet ${applet}"
		dosym uu-coreutils "/usr/bin/${applet}"
	done
	dosym uu-coreutils /usr/bin/coreutils
}
