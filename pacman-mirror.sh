#!/bin/sh

# This script helps Git for Windows developers to manage their Pacman
# repository.
#
# A Pacman repository is like a Git repository, but for binary packages.
#
# This script supports three commands:
#
# - 'fetch' to initialize (or update) a local mirror of the Pacman repository
#
# - 'add' to add packages to the local mirror
#
# - 'push' to synchronize local changes (after calling `repo-add`) to the
#   remote Pacman repository

die () {
	echo "$*" >&2
	exit 1
}

# MSys2's mingw-w64-$arch-ca-certificates seem to lag behind ca-certificates
CURL_CA_BUNDLE=/usr/ssl/certs/ca-bundle.crt
export CURL_CA_BUNDLE

mode=
case "$1" in
fetch|add|push)
	mode="$1"
	shift
	;;
*)
	die "Usage: $0 ( fetch | push | add <package>... )"
	;;
esac

base_url=https://dl.bintray.com/git-for-windows/pacman
api_url=https://api.bintray.com
content_url=$api_url/content/git-for-windows/pacman
packages_url=$api_url/packages/git-for-windows/pacman
mirror=/var/local/pacman-mirror

architectures="i686 x86_64"

arch_dir () { # <architecture>
	echo "$mirror/$1"
}

fetch () {
	for arch in $architectures
	do
		arch_url=$base_url/$arch
		dir="$(arch_dir $arch)"
		mkdir -p "$dir"
		(cd "$dir" &&
		 curl -sfO $arch_url/git-for-windows.db.tar.xz ||
		 continue
		 for name in $(package_list git-for-windows.db.tar.xz)
		 do
			case "$name" in
			mingw-w64-*)
				filename=$name-any.pkg.tar.xz
				;;
			*)
				filename=$name-$arch.pkg.tar.xz
				;;
			esac
			test -f $filename ||
			curl --cacert /usr/ssl/certs/ca-bundle.crt \
				-sfLO $base_url/$arch/$filename ||
			exit
		 done
		)
	done
}

upload () { # <package> <version> <arch> <filename>
	curl --netrc -fT "$4" "$content_url/$1/$2/$3/$4" ||
	die "Could not upload $4 to $1/$2/$3"
}

publish () { # <package> <version>
	curl --netrc -fX POST "$content_url/$1/$2/publish" ||
	die "Could not publish $2 in $1"
}


delete_version () { # <package> <version>
	curl --netrc -fX DELETE "$packages_url/$1/versions/$2" ||
	die "Could not delete version $2 of $1"
}

package_list () { # db.tar.xz
	tar tf "$1" |
	sed -n 's/\/$//p'
}

package_exists () { # package-name
	case "$(curl --netrc -s "$packages_url/$1")" in
	*\"name\":\""$1"\"*)
		return 0
		;;
	*)
		echo "Package $1 does not yet exist" >&2
		return 1
		;;
	esac
}

db_version () {
	json="$(curl --netrc -s \
		"$packages_url/package-database/versions/_latest")"
	latest="$(expr "$json" : '.*"name":"\([^"]*\)".*')"
	test -n "$latest" ||
	die "Could not determine latest version"

	echo "$latest"
}

next_db_version () { # old version
	today="$(date -u +%Y-%m-%d)"
	case "$1" in
	$today-*)
		echo $today-$((${1##*-}+1))
		;;
	*)
		echo $today-1
		;;
	esac
}

add () { # <file>
	test $# -gt 0 ||
	die "What packages do you want to add?"

	for path
	do
		case "${path##*/}" in
		mingw-w64-*.pkg.tar.xz)
			arch=${path##mingw-w64-}
			arch=${arch%%-*}
			;;
		*-*.pkg.tar.xz)
			arch=${path##*-}
			arch=${arch%.pkg.tar.xz}
			;;
		*)
			die "Invalid package name: $path"
			;;
		esac
		case " $architectures " in
		*" $arch "*)
			# okay
			;;
		*)
			die "Unknown architecture: $arch"
			;;
		esac
		dir="$(arch_dir $arch)"
		if test -d "$dir"
		then
			prefix="${path##*/}"
			prefix="${prefix%%-[0-9][0-9.]*}"
			(cd "$dir" &&
			 for file in "$prefix"-[0-9][0-9.]*
			 do
				rm -v "$file"
			 done)
		else
			mkdir -p "$dir"
		fi
		cp "$path" "$dir/"
	done
}

update_local_package_databases () {
	for arch in $architectures
	do
		(cd "$(arch_dir $arch)" &&
		 repo-add --new git-for-windows.db.tar.xz \
			*.pkg.tar.xz
		)
	done
}

push () {
	update_local_package_databases
	for arch in $architectures
	do
		arch_url=$base_url/$arch
		dir="$(arch_dir $arch)"
		mkdir -p "$dir"
		(cd "$dir" &&
		 echo "Getting $arch_url/git-for-windows.db.tar.xz" &&
		 curl -L $arch_url/git-for-windows.db.tar.xz > .remote
		) ||
		die "Could not get remote index for $arch"
	done

	old_list="$((for arch in $architectures
		do
			dir="$(arch_dir $arch)"
			test -s "$dir/.remote" &&
			package_list "$dir/.remote"
		done) |
		sort | uniq)"
	new_list="$((for arch in $architectures
		do
			dir="$(arch_dir $arch)"
			package_list "$dir/git-for-windows.db.tar.xz"
		done) |
		sort | uniq)"

	to_upload="$(printf "%s\n%s\n%s\n" "$old_list" "$old_list" "$new_list" |
		sort | uniq -u)"

	test -n "$to_upload" || {
		echo "Nothing to be done" >&2
		return
	}

	to_upload_basenames="$(echo "$to_upload" |
		sed 's/-[0-9].*//' |
		sort | uniq)"

	db_version="$(db_version)"
	next_db_version="$(next_db_version "$db_version")"

	# Verify that the packages exist already
	for basename in $to_upload_basenames
	do
		case " $(echo "$old_list" | tr '\n' ' ')" in
		*" $basename"-[0-9]*)
			;;
		*)
			package_exists $basename ||
			die "The package $basename does not yet exist... Add it at https://bintray.com/git-for-windows/pacman/new/package?pkgPath="
			;;
		esac
	done

	for name in $to_upload
	do
		basename=${name%%-[0-9]*}
		version=${name#$basename-}
		for arch in $architectures
		do
			case "$name" in
			mingw-w64-*)
				filename=$name-any.pkg.tar.xz
				;;
			*)
				filename=$name-$arch.pkg.tar.xz
				;;
			esac
			(cd "$(arch_dir $arch)" &&
			 if test -f $filename
			 then
				upload $basename $version $arch $filename
			 fi) || exit
		done
		publish $basename $version
	done

	delete_version package-database "$db_version"

	for arch in $architectures
	do
		(cd "$(arch_dir $arch)" &&
		 for suffix in db db.tar.xz files files.tar.xz
		 do
			filename=git-for-windows.$suffix
			test ! -f $filename ||
			upload package-database $next_db_version $arch $filename
		 done
		) || exit
	done
	publish package-database $next_db_version
}

eval "$mode" "$@"
