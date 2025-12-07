#!/bin/bash

source experiment/run-library.sh

manifest_exercise_runs="${PARAM_manifest_exercise_runs:-5}"

lces="${PARAM_lces:-Test QA Pre Prod}"
lces_comma="$(echo "$lces" | tr ' ' ',')"

rels="${PARAM_rels:-rhel7 rhel8 rhel9 rhel10}"

basearch=x86_64

rhel_product=RHEL
tested_products+=("$rhel_product")

sat_client_product='Satellite Client'
repo_sat_client="${PARAM_repo_sat_client:-http://mirror.example.com}"
tested_products+=("$sat_client_product")

rhosp_product=RHOSP
rhosp_registry_url="https://${PARAM_rhosp_registry:-https://registry.example.io}"
rhosp_registry_username="${PARAM_rhosp_registry_username:-user}"
rhosp_registry_password="${PARAM_rhosp_registry_password:-password}"
tested_products+=("$rhosp_product")

if vercmp_ge "$sat_version" '6.17.0'; then
    flatpak_product=Flatpak
    flatpak_remote=rhel
    flatpak_remote_url="https://${PARAM_flatpak_remote:-https://flatpak.example.io}"
    flatpak_remote_username="${PARAM_flatpak_remote_username:-user}"
    flatpak_remote_password="${PARAM_flatpak_remote_password:-password}"
    tested_products+=("$flatpak_product")
fi

initial_expected_concurrent_registrations="${PARAM_initial_expected_concurrent_registrations:-32}"

test_sync_repositories_count="${PARAM_test_sync_repositories_count:-8}"
test_sync_repositories_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"
test_sync_repositories_max_sync_secs="${PARAM_test_sync_repositories_max_sync_secs:-600}"
test_sync_repositories_le="${PARAM_test_sync_repositories_le:-test_sync_repositories_le}"
test_sync_iso_count="${PARAM_test_sync_iso_count:-8}"
test_sync_iso_url_template="${PARAM_test_sync_iso_url_template:-http://storage.example.com/iso-repos*}"
test_sync_iso_max_sync_secs="${PARAM_test_sync_iso_max_sync_secs:-600}"
test_sync_iso_le="${PARAM_test_sync_iso_le:-test_sync_iso_le}"
test_sync_docker_count="${PARAM_test_sync_docker_count:-8}"
test_sync_docker_url_template="${PARAM_test_sync_docker_url_template:-https://registry.example.io}"
test_sync_docker_max_sync_secs="${PARAM_test_sync_docker_max_sync_secs:-600}"
test_sync_docker_le="${PARAM_test_sync_docker_le:-test_sync_docker_le}"
test_sync_ansible_collections_count="${PARAM_test_sync_ansible_collections_count:-8}"
test_sync_ansible_collections_url_template="${PARAM_test_sync_ansible_collections_url_template:-https://galaxy.example.com/}"
test_sync_ansible_collections_max_sync_secs="${PARAM_test_sync_ansible_collections_max_sync_secs:-600}"
test_sync_ansible_collections_le="${PARAM_test_sync_ansible_collections_le:-test_sync_ansible_collections_le}"

rex_search_queries="${PARAM_rex_search_queries:-container110 container10 container0}"
rex_search_query_ssh="${PARAM_rex_search_query_ssh:-(name ~ ssh)}"
rex_search_query_mqtt="${PARAM_rex_search_query_mqtt:-(name ~ mqtt)}"

ui_concurrency="${PARAM_ui_concurrency:-10}"
ui_duration="${PARAM_ui_duration:-300}"
ui_max_static_size="${PARAM_ui_max_static_size:-40960}"


section 'Checking environment'
generic_environment_check
# unset skip_measurement
# set +e

# Initial version sanity check
for rel in $rels; do
    case "$rel" in
    rhel[7-9]|rhel10)
        continue
        ;;
    *)
        echo "Wrong release: $rel!!!" && exit
        ;;
    esac
done


section 'Create LCE(s)'
lifecycle_environments='[]'

# LCE creation
prior=Library
for lce in $lces; do
    lifecycle_environments="$(echo "$lifecycle_environments" |
      jq -c \
      --arg name "$lce" \
      --arg prior "$prior" \
      '. += [{"name": $name, "prior": $prior}]')"

    prior=$lce
done

test=01fr-lce-create
apj $test \
  -e "lifecycle_environments='$lifecycle_environments'" \
  playbooks/tests/FAM/lifecycle_environments.yaml


section 'Prepare for Red Hat content'
test=09f-manifest-download
skip_measurement=true apj $test \
  playbooks/tests/FAM/manifest_download.yaml

test=09f-manifest-excercise
skip_measurement=true apj $test \
  -e "runs='$manifest_exercise_runs'" \
  playbooks/tests/FAM/manifest_test.yaml
ej ManifestImport $test &
ej ManifestRefresh $test &
ej ManifestDelete $test &

test=09f-manifest-import
skip_measurement=true apj $test \
  playbooks/tests/FAM/manifest_import.yaml


# Get content
content_views='[]'
activation_keys='[]'

for product in "${tested_products[@]}"; do
    section "Get $product content"
    product_code="$(echo $product | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"
    product_underscore="$(echo $product | tr ' ' '_')"

    case "$product" in
    $rhel_product)
        index_ten=1
        ;;
    $sat_client_product)
        index_ten=2
        content_type=yum
        ;;
    $rhosp_product)
        index_ten=3
        content_type=docker
        ;;
    $flatpak_product)
        index_ten=4
        content_type=docker
        ;;
    esac

    product_products='[]'
    products='[]'

    if [[ "$product" == "$flatpak_product" ]]; then
        ### XXX
        # Create a product with an empty list of repos
        # This is needed because remote-repo-mirror will need a product
        product_products="$(echo "$product_products" |
          jq -c \
          --arg name "$product" \
          --argjson repositories '[]' \
          '. + [{"name": $name, "repositories": $repositories}]')"

        test="${index_ten}0fr-product-create-${product_code}-fake"
        apj $test \
          -e "products='$product_products'" \
          playbooks/tests/FAM/repositories.yaml
        ### XXX

        test="${index_ten}1f-flatpak_remote-create-${flatpak_remote}"
        apj $test \
          -e "flatpak_remote='$flatpak_remote'" \
          -e "flatpak_remote_url='${flatpak_remote_url}/${flatpak_remote}'" \
          -e "flatpak_remote_username='$flatpak_remote_username'" \
          -e "flatpak_remote_token='$flatpak_remote_password'" \
          playbooks/tests/FAM/flatpak_remote_create.yaml
        # ej FlatpakRemoteCreate $test

        ### XXX: This fails sometimes!!!
        test="${index_ten}2f-flatpak_remote-scan-${flatpak_remote}"
        apj $test \
          -e "flatpak_remote='$flatpak_remote'" \
          playbooks/tests/FAM/flatpak_remote_scan.yaml
        # ej FlatpakRemoteScan $test
    fi  # "$product" == "$flatpak_product"

    for rel in $rels; do
        rel_num="${rel##rhel}"
        product_code_rel_num="${product_code}_${rel_num}"

        if [[ "$product" == "$rhel_product" ]]; then
            ## OS
            repository_sets='[]'

            case "$rel_num" in
            7)
                releasever="${rel_num}Server"
                product_name='Red Hat Enterprise Linux Server'

                reposet_name="Red Hat Enterprise Linux $rel_num Server (RPMs)"
                repository_sets="$(echo "$repository_sets" |
                  jq -c \
                  --arg name "$reposet_name" \
                  --arg basearch "$basearch" \
                  --arg releasever "$releasever" \
                  '. += [{"name": $name, "basearch": $basearch, "releasever": $releasever}]')"

                # Extras
                reposet_name="Red Hat Enterprise Linux $rel_num Server - Extras (RPMs)"
                repository_sets="$(echo "$repository_sets" |
                  jq -c \
                  --arg name "$reposet_name" \
                  --arg basearch "$basearch" \
                  '. += [{"name": $name, "basearch": $basearch}]')"
                ;;
          *)
                releasever=$rel_num
                product_name="Red Hat Enterprise Linux for $basearch"

                # BaseOS
                reposet_name="Red Hat Enterprise Linux $rel_num for $basearch - BaseOS (RPMs)"
                repository_sets="$(echo "$repository_sets" |
                  jq -c \
                  --arg name "$reposet_name" \
                  --arg releasever "$releasever" \
                  '. += [{"name": $name, "releasever": $releasever}]')"

                # AppStream
                reposet_name="Red Hat Enterprise Linux $rel_num for $basearch - AppStream (RPMs)"
                repository_sets="$(echo "$repository_sets" |
                  jq -c \
                  --arg name "$reposet_name" \
                  --arg releasever "$releasever" \
                  '. += [{"name": $name, "releasever": $releasever}]')"
            esac  # case "$rel_num"

            product_products="$(echo "$product_products" |
              jq -c \
              --arg name "$product_name" \
              --argjson repository_sets "$repository_sets" \
              'if any(. | .name == $name) then
                map(if .name == $name then
                  .repository_sets += $repository_sets
                else
                  .
                end)
              else
                . + [{"name": $name, "repository_sets": $repository_sets}]
              end')"
        else  # "$product" != "$rhel_product"
            product_repositories='[]'

            case "$product" in
            $sat_client_product)
                repo_name="$product for RHEL $rel_num"
                repo_url="${repo_sat_client}/Satellite_Client_RHEL${rel_num}_${basearch}/"
                ;;
            $rhosp_product)
                case "$rel_num" in
                [8-9])
                # [8-9]|10)
                    repo_name="rhosp-${rel}/openstack-base"
                    repo_url="$rhosp_registry_url"
                    ;;
                *)
                    continue
                esac  # case "$rel_num"
                ;;
            $flatpak_product)
                case "$rel_num" in
                [8-9]|10)
                    # product_code_rel_num="${product_code}_${rel_num}"
                    product_underscore="$(echo $product | tr ' ' '_')"

                    flatpak_packages='flatpak-runtime flatpak-sdk'
                    (( "$rel_num" == 10 )) && flatpak_packages+=' firefox-flatpak thunderbird-flatpak'

                    for package in $flatpak_packages; do
                        repo_name="${rel}/${package}"
                        repo_name_code="$(echo ${repo_name} | tr ' ' '_' | tr '/' '_')"
                        product_code_rel_num_package="${product_code_rel_num}_${package}"

                        test="43f-flatpak-remote-repo-mirror-${repo_name_code}"
                        apj $test \
                          -e "product='$product'" \
                          -e "flatpak_remote='$flatpak_remote'" \
                          -e "flatpak_remote_repository='$repo_name'" \
                          playbooks/tests/FAM/flatpak_remote_repo_mirror.yaml
                        # ej FlatpakRemoteRepoMirror $test
                    done  # for package in $flatpak_packages
                    ;;
                *)
                    continue
                esac  # case "$rel_num"
                ;;
            esac  # case "$product"

            if [[ "$product" != "$flatpak_product" ]]; then
                if [[ "$product" == "$sat_client_product" ]]; then
                    product_repositories="$(echo "$product_repositories" |
                      jq -c \
                      --arg name "$repo_name" \
                      --arg url "$repo_url" \
                      --arg content_type "$content_type" \
                      '. += [{"name": $name, "url": $url, "content_type": $content_type}]')"
                elif [[ "$product" == "$rhosp_product" ]]; then
                    product_repositories="$(echo "$product_repositories" |
                      jq -c \
                      --arg name "$repo_name" \
                      --arg content_type "$content_type" \
                      --arg url "$repo_url" \
                      --arg docker_upstream_name "$repo_name" \
                      --arg upstream_username "$rhosp_registry_username" \
                      --arg upstream_password "$rhosp_registry_password" \
                      '. += [{"name": $name, "content_type": $content_type, "url": $url, "docker_upstream_name": $docker_upstream_name, "upstream_username": $upstream_username, "upstream_password": $upstream_password}]')"
                fi

                product_products="$(echo "$product_products" |
                  jq -c \
                  --arg name "$product" \
                  --argjson repositories "$product_repositories" \
                  'if any(. | .name == $name) then
                    map(if .name == $name then
                      .repositories += $repositories
                    else
                      .
                    end)
                  else
                    . + [{"name": $name, "repositories": $repositories}]
                  end')"
              fi  # "$product" != "$flatpak_product"
        fi  # "$product" == "$rhel_product"
    done  # for rel in $rels

    products="$(echo "$products" | jq -c \
      --argjson product_products "$product_products" \
      '. + $product_products')"

    # Set $product repositories
    test="${index_ten}0fr-product-create-${product_code}"
    apj $test \
      -e "products='$product_products'" \
      playbooks/tests/FAM/repositories.yaml

    # Sync $product products
    echo "$product_products" | jq -r '.[].name' | while read product; do
        product_code="$(echo $product | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"

        test="${index_ten}4f-product-sync-${product_code}"
        apj $test \
          -e "product='$product'" \
          playbooks/tests/FAM/repo_sync.yaml
    done  # while read product


    section "Create $product CVs/CCVs"
    for rel in $rels; do
        rel_num="${rel##rhel}"
        product_code_rel_num="${product_code}_${rel_num}"

        product_repositories='[]'
        components='[]'

        if [[ "$product" == "$rhel_product" ]]; then
            case "$rel_num" in
            7)
                releasever="${rel_num}Server"
                product_name='Red Hat Enterprise Linux Server'

                repo_name="Red Hat Enterprise Linux $rel_num Server RPMs $basearch $releasever"
                product_repositories="$(echo "$product_repositories" |
                  jq -c \
                  --arg name "$repo_name" \
                  --arg product "$product_name" \
                  '. + [{"name": $name, "product": $product}]')"

                # Extras
                repo_name="Red Hat Enterprise Linux $rel_num Server - Extras RPMs $basearch"
                product_repositories="$(echo "$product_repositories" |
                  jq -c \
                  --arg name "$repo_name" \
                  --arg product "$product_name" \
                  '. + [{"name": $name, "product": $product}]')"
                ;;
            *)
                releasever=$rel_num
                product_name="Red Hat Enterprise Linux for $basearch"

                # BaseOS
                repo_name="Red Hat Enterprise Linux $rel_num for $basearch - BaseOS RPMs $releasever"
                product_repositories="$(echo "$product_repositories" |
                  jq -c \
                  --arg name "$repo_name" \
                  --arg product "$product_name" \
                  '. + [{"name": $name, "product": $product}]')"

                # AppStream
                repo_name="Red Hat Enterprise Linux $rel_num for $basearch - AppStream RPMs $releasever"
                product_repositories="$(echo "$product_repositories" |
                  jq -c \
                  --arg name "$repo_name" \
                  --arg product "$product_name" \
                  '. + [{"name": $name, "product": $product}]')"
                ;;
            esac  # case "$rel_num"
        else  # "$product" != "$rhel_product"
            case "$product" in
            $sat_client_product)
                repo_name="$product for RHEL $rel_num"
                repo_name_code="$(echo ${repo_name} | tr ' ' '_' | tr '/' '_')"
                organization_underscore="$(echo $organization | tr ' ' '_')"
                content_label="${organization_underscore}_${product_underscore}_${repo_name_code}"
                content_overrides='[]'
                ;;
            $rhosp_product)
                case "$rel_num" in
                [8-9])
                # [8-9]|10)
                    repo_name="rhosp-${rel}/openstack-base"
                    repo_name_code="$(echo ${repo_name} | tr ' ' '_' | tr '/' '_')"
                    ;;
                *)
                    continue
                esac  # case "$rel_num"
                ;;
            $flatpak_product)
                case "$rel_num" in
                [8-9]|10)
                    flatpak_packages='flatpak-runtime flatpak-sdk'
                    (( "$rel_num" == 10 )) && flatpak_packages+=' firefox-flatpak thunderbird-flatpak'

                    for package in $flatpak_packages; do
                        repo_name="${rel}/${package}"
                        repo_name_code="$(echo ${repo_name} | tr ' ' '_' | tr '/' '_')"

                        product_repositories="$(echo "$product_repositories" |
                          jq -c \
                            --arg name "$repo_name" \
                            --arg product "$product" \
                            '. + [{"name": $name, "product": $product}]')"
                    done  # for package in $flatpak_packages
                    ;;
                *)
                    continue
                esac  # case "$rel_num"
            esac  # case "$product"

            if [[ "$product" != "$flatpak_product" ]]; then
                product_repositories="$(echo "$product_repositories" |
                  jq -c \
                    --arg name "$repo_name" \
                    --arg product "$product" \
                    '. + [{"name": $name, "product": $product}]')"
            fi  # "$product" != "$flatpak_product"
        fi  # "$product" == "$rhel_product"

        # CV
        cv="CV_${product_code_rel_num}"
        content_views="$(echo "$content_views" |
          jq -c \
          --arg name "$cv" \
          --argjson repositories "$product_repositories" \
          '. + [{"name": $name, "repositories": $repositories}]')"

        # CCV
        ccv="CCV_${rel_num}"
        components="$(echo "$components" |
          jq -c \
          --arg content_view "$cv" \
          '. + [{"content_view": $content_view, "latest": "true"}]')"

        # XXX: Publication + promotion can be done in one pass with the
        #      content_view_publish role, but we prefer to split it to
        #      measure both independently
        # content_views="$(echo "$content_views" |
        #   jq -c \
        #   --arg name "$ccv" \
        #   --argjson components "$components" \
        #   --arg lifecycle_environments "$lces_comma" \
        #   'if any(. | .name == $name) then
        #     map(if .name == $name then
        #       .components += $components
        #     else
        #       .
        #     end)
        #   else
        #     . + [{"name": $name, "components": $components, "lifecycle_environments": $lifecycle_environments}]
        #   end |
        #   sort | reverse')"
        content_views="$(echo "$content_views" |
          jq -c \
          --arg name "$ccv" \
          --argjson components "$components" \
          'if any(. | .name == $name) then
            map(if .name == $name then
              .components += $components
            else
              .
            end)
          else
            . + [{"name": $name, "components": $components}]
          end |
          sort | reverse')"

        if [[ "$product" != "$sat_client_product" ]]; then
            for lce in $lces; do
                ak="AK_${rel_num}_${lce}"

                activation_keys="$(echo "$activation_keys" |
                  jq -c \
                  --arg name "$ak" \
                  --arg lifecycle_environment "$lce" \
                  --arg content_view "$ccv" \
                  'if any(. | .name == $name) then
                    .
                  else
                    . + [{"name": $name, "lifecycle_environment": $lifecycle_environment, "content_view": $content_view}]
                  end')"
            done  # for lce in $lces
        else  # "$product" == "$sat_client_product"
            content_overrides="$(echo "$content_overrides" |
              jq -c \
              --arg label "$content_label" \
              '. += [{"label": $label, "override": "enabled"}]')"

            for lce in $lces; do
                ak="AK_${rel_num}_${lce}"

                activation_keys="$(echo "$activation_keys" |
                  jq -c \
                  --arg name "$ak" \
                  --arg lifecycle_environment "$lce" \
                  --arg content_view "$ccv" \
                  --argjson content_overrides "$content_overrides" \
                  'if any(. | .name == $name) then
                    map(if .name == $name then
                      .content_overrides += $content_overrides
                    else
                      .
                    end)
                  else
                    . + [{"name": $name, "lifecycle_environment": $lifecycle_environment, "content_view": $content_view, "content_overrides": $content_overrides}]
                  end')"
            done  # for lce in $lces
        fi  # "$product" != "$sat_client_product"
    done  # for rel in $rels

    product_content_views="$(echo "$content_views" |
      jq -c \
      --arg product_code "CV_${product_code}_" \
      'map(select(.components or (.repositories and (.name | test($product_code)))))')"

    # Create $product CVs/CCVs
    test="${index_ten}5fr-cv-create-${product_code}"
    apj $test \
      -e "content_views='$product_content_views'" \
      playbooks/tests/FAM/content_views.yaml

    # Publish $product CVs/CCVs
    test="${index_ten}5fr-cv-publish-${product_code}"
    # XXX: Publication + promotion can be done in one pass with the
    #      content_view_publish role, but we prefer to split it to
    #      measure both independently
    apj $test \
      -e "content_views='$product_content_views'" \
      playbooks/tests/FAM/content_view_publish.yaml

    # Promote $product CCVs to LCEs
    test="${index_ten}6f-ccv-version-promote-${product_code}"
    # XXX: Publication + promotion can be done in one pass with the
    #      content_view_publish role, but we prefer to split it to
    #      measure both independently
    # apj $test \
    #   -e "content_views='$product_content_views'" \
    #   -e "current_lifecycle_environment=Library" \
    #   -e "lifecycle_environments='$lces_comma'" \
    #   playbooks/tests/FAM/cv_version_promote.yaml
    apj $test \
      -e "content_views='$product_content_views'" \
      -e "lifecycle_environments='$lces_comma'" \
      playbooks/tests/FAM/cv_version_promote.yaml

    # Create/update AKs
    test="${index_ten}7fr-ak-create_update-${product_code}"
    apj $test \
      -e "activation_keys='$activation_keys'" \
      playbooks/tests/FAM/activation_keys.yaml
done  # for product


# Sync several types of content
contents='yum iso docker ansible-collections'

for content in $contents; do
    case "$content" in
    yum)
        index=80
        content_alias=repositories
        test_count_var="test_sync_${content_alias}_count"
        test_url_template_var="test_sync_${content_alias}_url_template"
        test_max_sync_secs_var="test_sync_${content_alias}_max_sync_secs"
        test_le_var="test_sync_${content_alias}_le"
        test_count_value="$test_sync_repositories_count"
        test_url_template_value="$test_sync_repositories_url_template"
        test_max_sync_secs_value="$test_sync_repositories_max_sync_secs"
        test_le_value="$test_sync_repositories_le"
        ;;
    iso)
        index=81
        content_alias="$content"
        test_count_var="test_sync_${content_alias}_count"
        test_url_template_var="test_sync_${content_alias}_url_template"
        test_max_sync_secs_var="test_sync_${content_alias}_max_sync_secs"
        test_le_var="test_sync_${content_alias}_le"
        test_count_value="$test_sync_iso_count"
        test_url_template_value="$test_sync_iso_url_template"
        test_max_sync_secs_value="$test_sync_iso_max_sync_secs"
        test_le_value="$test_sync_iso_le"
        ;;
    docker)
        index=82
        content_alias="$content"
        test_count_var="test_sync_${content_alias}_count"
        test_url_template_var="test_sync_${content_alias}_url_template"
        test_max_sync_secs_var="test_sync_${content_alias}_max_sync_secs"
        test_le_var="test_sync_${content_alias}_le"
        test_count_value="$test_sync_docker_count"
        test_url_template_value="$test_sync_docker_url_template"
        test_max_sync_secs_value="$test_sync_docker_max_sync_secs"
        test_le_value="$test_sync_docker_le"
        ;;
    ansible-collections)
        index=82
        content_alias=ansible_collections
        test_count_var="test_sync_${content_alias}_count"
        test_url_template_var="test_sync_${content_alias}_url_template"
        test_max_sync_secs_var="test_sync_${content_alias}_max_sync_secs"
        test_le_var="test_sync_${content_alias}_le"
        test_count_value="$test_sync_ansible_collections_count"
        test_url_template_value="$test_sync_ansible_collections_url_template"
        test_max_sync_secs_value="$test_sync_ansible_collections_max_sync_secs"
        test_le_value="$test_sync_ansible_collections_le"
        ;;
    esac  # case "$content"


    section "Sync $content content"
    test="${index}-test-sync-${content_alias}"
    ap "${test}.log" \
      -e "organization='{{ sat_org }}'" \
      -e "$test_count_var='$test_count_value'" \
      -e "$test_url_template_var='$test_url_template_value'" \
      -e "$test_max_sync_secs_var='$test_max_sync_secs_value'" \
      -e "$test_le_var='$test_le_value'" \
      playbooks/tests/sync-${content_alias}.yaml
    e SyncRepositories "${logs}/${test}.log"
    e PublishContentViews "${logs}/${test}.log"
    e PromoteContentViews "${logs}/${test}.log"
done  # for content in $contents


section 'Prepare for registrations'
unset aks
for rel in $rels; do
    rel_num="${rel##rhel}"

    for lce in $lces; do
        ak="AK_${rel_num}_${lce}"
        aks+=" $ak"
    done
done

# XXX: FAM: theforeman.foreman.registration_command
ap 44-generate-host-registration-commands.log \
  -e "organization='{{ sat_org }}'" \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  -e "enable_iop='$enable_iop'" \
  playbooks/satellite/host-registration_generate-commands.yaml

ap 44-recreate-client-scripts.log \
  -e "aks='$aks'" \
  -e "sat_version='$sat_version'" \
  playbooks/satellite/client-scripts.yaml


section 'Incremental registrations'
num_containers_per_container_host="$( get_inventory_var containers_count container_hosts[0] )"
min_containers_per_batch=4
num_retry_forks="$(( initial_expected_concurrent_registrations / num_container_hosts ))"
initial_concurrent_registrations_per_container_host=$min_containers_per_batch
num_retry_forks=$min_containers_per_batch
prefix=48-register

for (( batch=1, remaining_containers_per_container_host=num_containers_per_container_host, total_registered=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_registrations_per_container_host * batch )); then
        concurrent_registrations_per_container_host="$(( initial_concurrent_registrations_per_container_host * batch ))"
    else
        concurrent_registrations_per_container_host=$remaining_containers_per_container_host
    fi
    concurrent_registrations="$(( concurrent_registrations_per_container_host * num_container_hosts ))"
    (( remaining_containers_per_container_host -= concurrent_registrations_per_container_host ))
    (( total_registered += concurrent_registrations ))

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    test="${prefix}-${concurrent_registrations}"
    ap "${test}.log" \
      -e "size='$concurrent_registrations_per_container_host'" \
      -e "concurrent_registrations='$concurrent_registrations'" \
      -e "num_retry_forks='$num_retry_forks'" \
      -e "registration_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      -e "profile='$profiling_enabled'" \
      -e "registration_profile_img='$test.svg'" \
      playbooks/tests/registrations.yaml
    e Register "${logs}/${test}.log"
done
grep Register "$logs"/$prefix-*.log >"$logs/$prefix-overall.log"
e Register "$logs/$prefix-overall.log"


section 'Misc simple tests'
test=50-hammer-list
ap "${test}.log" \
  -e "organization='{{ sat_org }}'" \
  playbooks/tests/hammer-list.yaml
e HammerHostList "${logs}/${test}.log"

rm -f /tmp/status-data-webui-pages.json
test=51-webui-pages
ap "${test}.log" \
  -e "sat_version='$sat_version'" \
  -e "ui_concurrency='$ui_concurrency'" \
  -e "ui_duration='$ui_duration'" \
  playbooks/tests/webui-pages.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-pages.json e "WebUIPagesTest_c${ui_concurrency}_d${ui_duration}" "${logs}/${test}.log"

rm -f /tmp/status-data-webui-static-distributed.json
test=52-webui-static-distributed
ap "${test}.log" \
  -e "sat_version='$sat_version'" \
  -e "ui_concurrency='$ui_concurrency'" \
  -e "ui_duration='$ui_duration'" \
  -e "ui_max_static_size='$ui_max_static_size'" \
  playbooks/tests/webui-static-distributed.yaml
STATUS_DATA_FILE=/tmp/status-data-webui-static-distributed.json e "WebUIStaticDistributedTest_c${ui_concurrency}_d${ui_duration}" "${logs}/${test}.log"


section 'Sosreport'
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
