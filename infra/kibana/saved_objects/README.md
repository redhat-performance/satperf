Satellite CPT Kibana saved objects storage
==========================================

To update objects here from Kibana or to update objects in Kibana with
configs here, please follow guide in:

<https://github.com/redhat-performance/kibana_objects_tool>


To clone dashboard visualizations from ver X to Y
-------------------------------------------------

First, make sure you have latest visualization JSONs using
`kibana_objects_tool` refferenced above.

Lets say I want to create Sat 6.11 visualizations based on their
6.10 versions. I need to locate them:

    $ where/is/kibana_objects_tool/kibana_objects_tool.py list_objects | grep 6.10
    visualization_a1b1186a-7df8-47d8-92f1-2e909293d261.json visualization 'Sat 6.10 webui-pages' 3375 B
    visualization_d3531489-3487-4637-9783-0fc6a0e356a7.json visualization 'Sat 6.10 hammer-list' 3360 B
    visualization_038ba516-86ab-4cba-97cb-0bce1f20f0b3.json visualization 'Sat 6.10 Sync RHEL6 from mirror' 3434 B
    [...]

Now I can clone them:

    for f in $( where/is/kibana_objects_tool/kibana_objects_tool.py list_objects | grep 6.10 | cut -d ' ' -f 1 ); do
        ./clone_kibana_vis.py \
            --change-text 'Sat 6.10 ' 'Sat 6.11 ' \
            --change-version-wildcard '*-6.10.*' '*-6.11.*' \
            --change-version-match '6.10.z' '6.11.z' \
            -d --filename $f
    done

No traceback for none of them? Great.

Do not git add and commit these `new-*` files, they are temporary only.

Now you can create one NDJSON file from all of generated ones:

    for f in new-*.ndjson; do cat $f; echo; done >new.ndjson

And import it to Kibana (well, we have 'OpenSearch Dashboards' now):

    curl -X POST 'http://kibana.example.com/api/saved_objects/_import?overwrite=false' -H "osd-xsrf: true" --form file=@new.ndjson

Now you can delete temporary ones with `rm new*` and use `kibana_objects_tool`
process to get JSONs (these you just imported into Kibana) from Kibana into git.
