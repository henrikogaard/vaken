#!/usr/bin/env python3
"""Validate a stable release tag without changing versions, tags or remote state."""
import argparse
import json
import os
import pathlib
import re
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def positive_build(value):
    if not re.fullmatch(r"[1-9][0-9]*", value) or int(value) > 2**64 - 1:
        raise ValueError("Build must be a canonical positive UInt64 integer.")
    return int(value)


def validate_metadata(source, tag):
    if not re.fullmatch("v" + VERSION, tag):
        raise ValueError("Release tag must be stable vMAJOR.MINOR.PATCH without leading zeroes.")
    values = {}
    for field, name in [("version", "releaseVersion"), ("build", "releaseBuild")]:
        matches = re.findall(r'^\s*static let ' + name + r' = "([^"\n]+)"\s*$', source, re.M)
        if len(matches) != 1:
            raise ValueError("Expected exactly one committed " + name + " value.")
        values[field] = matches[0]
    if values["version"] != tag[1:]:
        raise ValueError("Tag does not match the committed app version.")
    positive_build(values["build"])
    return values


def validate_repository(repository):
    part = r"[A-Za-z0-9][A-Za-z0-9_.-]*"
    if not re.fullmatch(part + "/" + part, repository):
        raise ValueError("Repository must be a safe owner/name pair.")
    return repository


def published_build(data):
    if len(data) > 1024 * 1024 or b"<!DOCTYPE" in data.upper():
        raise ValueError("Published appcast is oversized or declares a DTD.")
    try:
        root = ET.fromstring(data)
        values = []
        for item in root.findall("./channel/item"):
            value = item.findtext(SPARKLE + "version")
            if value is None:
                enclosure = item.find("enclosure")
                value = enclosure.get(SPARKLE + "version") if enclosure is not None else None
            if value is None:
                raise ValueError("Published item has no build identifier.")
            values.append(positive_build(value.strip()))
        if not values:
            raise ValueError("Published appcast has no update items.")
        return max(values)
    except ET.ParseError as error:
        raise ValueError("Published appcast is not valid XML.") from error


def validate_remote(repository, tag, values, api, download):
    validate_repository(repository)
    if api(f"repos/{repository}/releases/tags/{tag}") is not None:
        raise ValueError("A release already exists for this tag; it will not be overwritten.")
    latest = api(f"repos/{repository}/releases/latest")
    if latest is None:
        return
    old_tag = latest.get("tag_name", "")
    if not re.fullmatch("v" + VERSION, old_tag):
        raise ValueError("Latest published release does not have a stable version tag.")
    if tuple(map(int, values["version"].split("."))) <= tuple(map(int, old_tag[1:].split("."))):
        raise ValueError("Version must be newer than the latest published stable release.")
    url = f"https://github.com/{repository}/releases/download/{old_tag}/appcast.xml"
    if positive_build(values["build"]) <= published_build(download(url)):
        raise ValueError("Build must be higher than every build in the latest published appcast.")


def github_api(path):
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    request = urllib.request.Request("https://api.github.com/" + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        if status == 404:
            return None
        raise RuntimeError(f"GitHub API failed with HTTP {status}; release preparation blocked.") from None


def download_feed(url):
    # Public release assets need no token. Never forward API credentials to redirects.
    with urllib.request.urlopen(url, timeout=30) as response:
        if urllib.parse.urlsplit(response.url).scheme != "https":
            raise ValueError("Published feed redirected away from HTTPS.")
        return response.read(1024 * 1024 + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--app-info", type=pathlib.Path, default=pathlib.Path("Sources/Vaken/AppInfo.swift"))
    parser.add_argument("--check-remote", action="store_true")
    parser.add_argument("--github-output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        validate_repository(args.repository)
        values = validate_metadata(args.app_info.read_text(), args.tag)
        if args.check_remote:
            validate_remote(args.repository, args.tag, values, github_api, download_feed)
        values["feed_url"] = f"https://github.com/{args.repository}/releases/latest/download/appcast.xml"
        values["download_prefix"] = f"https://github.com/{args.repository}/releases/download/{args.tag}/"
        if args.github_output:
            with args.github_output.open("a") as output:
                for key, value in values.items():
                    output.write(f"{key}={value}\n")
        print(json.dumps(values, sort_keys=True))
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"Release metadata validation failed: {error}\n")


if __name__ == "__main__":
    main()
