#!/usr/bin/env python3

import argparse
import json
import logging
import logging.handlers
import sys
import uuid
import dpath.util


def _setup_logger(app_name, stderr_log_lvl):
    """
    Create logger that logs to both stderr and log file but with different log level
    """
    # Change root logger level from WARNING (default) to NOTSET in order for all messages to be delegated.
    logging.getLogger().setLevel(logging.NOTSET)

    # Log message format
    formatter = logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s")

    # Add stderr handler, with level INFO
    console = logging.StreamHandler()
    console.setLevel(stderr_log_lvl)
    console.setFormatter(formatter)
    logging.getLogger().addHandler(console)

    # Add file rotating handler, with level DEBUG
    rotating_handler = logging.handlers.RotatingFileHandler(
        filename="/tmp/clone_kibana_vis.log", maxBytes=100 * 1000, backupCount=2
    )
    rotating_handler.setLevel(logging.DEBUG)
    rotating_handler.setFormatter(formatter)
    logging.getLogger().addHandler(rotating_handler)

    return logging.getLogger(app_name)


def json_set_in(logger, data, key, value):
    """
    Dump value to JSON string and set it into the document key
    """
    value_json = json.dumps(value, sort_keys=True, separators=(",", ":"))
    dpath.util.set(data, key, value_json)


def text_set_in(logger, data, key, text_new):
    """
    Set given path in the dict to given value
    """
    text = dpath.util.get(data, key)
    logger.debug(f"Loaded {key}: {text}")

    if text != text_new:
        logger.info(f"Set {key} to '{text_new}'")
        dpath.util.set(data, key, text_new)


def text_replace_in(logger, data, key, text_from, text_to):
    """
    Modify given path in the dict using replacing substring from/to
    """
    try:
        text = dpath.util.get(data, key)
    except KeyError:
        logger.warning(f"Failed to load path {key}, skipping")
        return
    logger.debug(f"Loaded {key}: {text}")

    text_new = text.replace(text_from, text_to)

    if text != text_new:
        logger.info(f"Changed {key} from '{text_from}' to '{text_to}'")
        dpath.util.set(data, key, text_new)


def modify_searchSourceJSON_value(logger, args, document_source, path):
    """
    Modify filter/1/meta/value content if it is JSON string

    See:
    cat visualization-....json | jq --raw-output '.[0].attributes.kibanaSavedObjectMeta.searchSourceJSON' | jq -S
    """
    # Load the document, for some visualizations it is not JSON string
    # and we can skip it
    try:
        document_json = dpath.util.get(document_source, path)
    except KeyError:
        logger.warning(f"Failed to load path {path}, skipping")
        return
    try:
        document = json.loads(document_json)
    except json.decoder.JSONDecodeError:
        logger.warning(f"Path {path} is not a JSON document")
        return

    # Modify the value
    text_replace_in(
        logger,
        document,
        "wildcard/parameters.version.keyword",
        *args.change_version_wildcard,
    )

    # Put the modified document back
    json_set_in(logger, document_source, path, document)

def modify_searchSourceJSON(logger, args, document_source, path):
    """
    Modify 0/attributes/kibanaSavedObjectMeta/searchSourceJSON JSON scring content
    """
    # Load document
    document_json = dpath.util.get(document_source, path)
    document = json.loads(document_json)

    for i in range(len(document["filter"])):
        # Modify the value
        text_replace_in(
            logger,
            document,
            f"filter/{i}/query/wildcard/parameters.version.keyword",
            *args.change_version_wildcard,
        )
        text_replace_in(
            logger,
            document,
            f"filter/{i}/query/match/parameters.version.keyword/query",
            *args.change_version_match,
        )
        text_replace_in(
            logger,
            document,
            f"filter/{i}/meta/params/query",
            *args.change_version_match,
        )
        text_replace_in(
            logger,
            document,
            f"filter/{i}/meta/params/value",
            *args.change_version_match,
        )

        # More modifications
        modify_searchSourceJSON_value(logger, args, document, f"filter/{i}/meta/value")

    # Put the modified document back
    json_set_in(logger, document_source, path, document)


def modify_visState(logger, args, document_source, path):
    """
    Modify  JSON scring content 0/attributes/visState
    """
    # Load document
    document_json = dpath.util.get(document_source, path)
    document = json.loads(document_json)

    # Modify the value
    text_replace_in(
        logger,
        document,
        "title",
        *args.change_text,
    )

    # Put the modified document back
    json_set_in(logger, document_source, path, document)


def modify_main(logger, args, document, document_uuid):
    text_set_in(
        logger,
        document,
        "0/id",
        document_uuid,
    )
    text_replace_in(
        logger,
        document,
        "0/attributes/title",
        *args.change_text,
    )
    text_replace_in(
        logger,
        document,
        "0/attributes/description",
        *args.change_text,
    )

    modify_searchSourceJSON(logger, args, document, "0/attributes/kibanaSavedObjectMeta/searchSourceJSON")
    modify_visState(logger, args, document, "0/attributes/visState")


def doit(logger, args):
    """
    Create a clone of input document, modyfying it as requested
    """
    with open(args.filename, "r") as fp:
        document = json.load(fp)
        logger.debug(f"Loaded {args.filename}: {document}")

    assert (
        len(document) == 1
    ), f"There should be exactly one document in {args.filename}"

    # Determine UUID for new document
    if args.new_uuid is None:
        document_uuid = str(uuid.uuid4())
    else:
        document_uuid = args.new_uuid

    # Modify the document
    modify_main(logger, args, document, document_uuid)

    # Save the modified document
    document_new_json = f"new-{document_uuid}.json"
    document_new_ndjson = f"new-{document_uuid}.ndjson"
    with open(document_new_json, "w") as fp:
        json.dump(document, fp, sort_keys=True, indent=4, separators=(",", ": "))
    with open(document_new_ndjson, "w") as fp:
        json.dump(document[0], fp, sort_keys=True, separators=(",", ": "))
    logger.debug(
        f"Cloned document saved to {document_new_json} and {document_new_ndjson}"
    )


def main():
    parser = argparse.ArgumentParser(prog="Clone visualization with some changes")
    parser.add_argument("-d", "--debug", action="store_true", help="Debug output")
    parser.add_argument("--filename", required=True, help="Clone this file")
    parser.add_argument("--new-uuid", help="UUID of new file")
    parser.add_argument(
        "--change-text",
        required=True,
        nargs=2,
        help="Substring to change in textual fields and its new value",
    )
    parser.add_argument(
        "--change-version-wildcard",
        required=True,
        nargs=2,
        help="Version expression to change from and to",
    )
    parser.add_argument(
        "--change-version-match",
        required=True,
        nargs=2,
        help="Simplified version like 6.10.z to change from and to",
    )
    args = parser.parse_args()

    logger = _setup_logger(
        "clone_kibana_vis", logging.DEBUG if args.debug else logging.WARNING
    )

    logger.debug(f"Args: {args}")

    return doit(logger, args)


if __name__ == "__main__":
    sys.exit(main())
