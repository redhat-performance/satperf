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


    section "Push $product content to capsules"
    test="${index_ten}9-capsules-sync-${product_code}"
    ap "${test}.log" \
      -e "organization='{{ sat_org }}'" \
      -e "lces='$lces'" \
      playbooks/tests/capsules-sync.yaml
    # e CapusuleSync "${logs}/${test}.log"
done  # for product


# section 'Create, publish and promote big CV'
product_code=Bench
index_ten=6

product_lifecycle_environments='[]'
product_repositories='[]'

# LCE creation
lces_bench="${product_code}LifeEnvAAA ${product_code}LifeEnvBBB ${product_code}LifeEnvCCC"

prior=Library
for lce in ${lces_bench}; do
    lifecycle_environments="$(echo "$lifecycle_environments" |
      jq -c \
      --arg name "$lce" \
      --arg prior "$prior" \
      '. += [{"name": $name, "prior": $prior}]')"

    prior=$lce
done

product_lifecycle_environments="$(echo "$lifecycle_environments" |
  jq -c \
  --arg lce_name "${product_code}LifeEnv" \
  'map(select(.name | test($lce_name)))')"

test="${index_ten}0fr-lce-create-big"
apj $test \
  -e "lifecycle_environments='$product_lifecycle_environments'" \
  playbooks/tests/FAM/lifecycle_environments.yaml

# CVs creation
for rel in $rels; do
    rel_num="${rel##rhel}"

    case "$rel_num" in
    7)
        releasever="${rel_num}Server"
        product='Red Hat Enterprise Linux Server'

        repo_name="Red Hat Enterprise Linux $rel_num Server RPMs $basearch $releasever"
        product_repositories="$(echo "$product_repositories" |
          jq -c \
          --arg product "$product" \
          --arg name "$repo_name" \
          '. + [{"product": $product, "name": $name}]')"

        # Extras
        repo_name_extras="Red Hat Enterprise Linux $rel_num Server - Extras RPMs $basearch"
        product_repositories="$(echo "$product_repositories" |
          jq -c \
          --arg product "$product" \
          --arg name "$repo_name_extras" \
          '. + [{"product": $product, "name": $name}]')"
        ;;
    *)
        releasever=$rel_num
        product="Red Hat Enterprise Linux for $basearch"

        # BaseOS
        repo_name="Red Hat Enterprise Linux $rel_num for $basearch - BaseOS RPMs $releasever"
        product_repositories="$(echo "$product_repositories" |
          jq -c \
          --arg product "$product" \
          --arg name "$repo_name" \
          '. + [{"product": $product, "name": $name}]')"

        # AppStream
        repo_name_appstream="Red Hat Enterprise Linux $rel_num for $basearch - AppStream RPMs $releasever"
        product_repositories="$(echo "$product_repositories" |
          jq -c \
          --arg product "$product" \
          --arg name "$repo_name_appstream" \
          '. + [{"product": $product, "name": $name}]')"
        ;;
    esac  # case "$rel_num"
done

# CV
cv="CV_${product_code}"
content_views="$(echo "$content_views" |
  jq -c \
  --arg name "$cv" \
  --argjson repositories "$product_repositories" \
  '. + [{"name": $name, "repositories": $repositories}]')"

product_content_views="$(echo "$content_views" |
  jq -c \
  --arg product_code "CV_${product_code}" \
  'map(select(.components or (.repositories and (.name | test($product_code)))))')"

# Create $product_code CV
test="${index_ten}5fr-cv-create-big-${product_code}"
apj $test \
  -e "content_views='$product_content_views'" \
  playbooks/tests/FAM/content_views.yaml

# Publish $product_code CV
test="${index_ten}5fr-cv-publish-big-${product_code}"
# XXX: Publication + promotion can be done in one pass with the
#      content_view_publish role, but we prefer to split it to
#      measure both independently
apj $test \
  -e "content_views='$product_content_views'" \
  playbooks/tests/FAM/content_view_publish.yaml

# Promote $product_code CV
test="${index_ten}6f-cv-version-promote-big-${cv}"
# XXX: Publication + promotion can be done in one pass with the
#      content_view_publish role, but we prefer to split it to
#      measure both independently
# apj $test \
#   -e "cv='$cv'" \
#   -e "current_lifecycle_environment=Library" \
#   -e "lifecycle_environments='$lces_comma'" \
#   playbooks/tests/FAM/cv_version_promote.yaml
apj $test \
  -e "cv='$cv'" \
  -e "lifecycle_environments='$lces_comma'" \
  playbooks/tests/FAM/cv_version_promote.yaml


# section 'Create, publish and promote filtered CV'
product_code=BenchFiltered
index_ten=7

product_lifecycle_environments='[]'
product_repositories='[]'

# LCE creation
lce_bench=${product_code}LifeEnv

lifecycle_environments="$(echo "$lifecycle_environments" |
  jq -c \
  --arg name "$lce_bench" \
  --arg prior 'Library' \
  '. += [{"name": $name, "prior": $prior}]')"

product_lifecycle_environments="$(echo "$lifecycle_environments" |
  jq -c \
  --arg lce_name "${product_code}LifeEnv" \
  'map(select(.name | test($lce_name)))')"

test="${index_ten}5fr-lce-create-filtered"
apj $test \
  -e "lifecycle_environments='$product_lifecycle_environments'" \
  playbooks/tests/FAM/lifecycle_environments.yaml

# CV creation
rel=rhel9
rel_num="${rel##rhel}"
releasever=$rel_num
product="Red Hat Enterprise Linux for $basearch"

repo_name="Red Hat Enterprise Linux $rel_num for $basearch - BaseOS RPMs $releasever"
product_repositories="$(echo "$product_repositories" |
  jq -c \
  --arg product "$product" \
  --arg name "$repo_name" \
  '. += [{"product": $product, "name": $name}]')"

# Filters and filter rules
filters='[]'

# AAA
suffix=AAA
filter_name="${product_code}${suffix}"
filter_type=erratum
filter_inclusion=true
filter_rule_date_type=issued
filter_rule_start_date='2024-01-01'
filter_rule_end_date='2025-01-01'
filters="$(echo "$filters" |
  jq -c \
  --arg name "$filter_name" \
  --arg filter_type "$filter_type" \
  --arg inclusion "$filter_inclusion" \
  --arg date_type "$filter_rule_date_type" \
  --arg start_date "$filter_rule_start_date" \
  --arg end_date "$filter_rule_end_date" \
  '. += [{"name": $name, "filter_type": $filter_type, "inclusion": $inclusion, "date_type": $date_type, "start_date": $start_date, "end_date": $end_date}]')"

# BBB
suffix=BBB
filter_name="${product_code}${suffix}"
filter_type=erratum
filter_inclusion=true
filter_rule_date_type=updated
filter_rule_types='["security"]'
filter_rule_start_date='2024-01-01'
filter_rule_end_date='2025-01-01'
filters="$(echo "$filters" |
  jq -c \
  --arg name "$filter_name" \
  --arg filter_type "$filter_type" \
  --arg inclusion "$filter_inclusion" \
  --arg date_type "$filter_rule_date_type" \
  --argjson types "$filter_rule_types" \
  --arg start_date "$filter_rule_start_date" \
  --arg end_date "$filter_rule_end_date" \
  '. += [{"name": $name, "filter_type": $filter_type, "inclusion": $inclusion, "date_type": $date_type, "types": $types, "start_date": $start_date, "end_date": $end_date}]')"

# CV
cv="CV_${product_code}"
content_views="$(echo "$content_views" |
  jq -c \
  --arg name "$cv" \
  --argjson repositories "$product_repositories" \
  --argjson filters "$filters" \
  '. + [{"name": $name, "repositories": $repositories, "filters": $filters}]')"

product_content_views="$(echo "$content_views" |
  jq -c \
  --arg product_code "CV_${product_code}" \
  'map(select(.components or (.repositories and (.name | test($product_code)))))')"

# Create $product_code CV
test="${index_ten}6fr-cv-create-filtered-${product_code}"
apj $test \
  -e "content_views='$product_content_views'" \
  playbooks/tests/FAM/content_views.yaml

# Publish $product_code CV
test="${index_ten}5fr-cv-publish-filtered-${product_code}"
# XXX: Publication + promotion can be done in one pass with the
#      content_view_publish role, but we prefer to split it to
#      measure both independently
apj $test \
  -e "content_views='$product_content_views'" \
  playbooks/tests/FAM/content_view_publish.yaml

# Promote $product_code CV
test="${index_ten}6f-cv-version-promote-filtered-${cv}"
# XXX: Publication + promotion can be done in one pass with the
#      content_view_publish role, but we prefer to split it to
#      measure both independently
# apj $test \
#   -e "cv='$cv'" \
#   -e "current_lifecycle_environment=Library" \
#   -e "lifecycle_environments='$lces_comma'" \
#   playbooks/tests/FAM/cv_version_promote.yaml
apj $test \
  -e "cv='$cv'" \
  -e "lifecycle_environments='$lces_comma'" \
  playbooks/tests/FAM/cv_version_promote.yaml


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


    section "Push $content content to capsules"
    test="${index}-capsules-sync-${content}"
    ap "${test}.log" \
      -e "organization='{{ sat_org }}'" \
      -e "lces='$test_le_value'" \
      playbooks/tests/capsules-sync.yaml
    e CapusuleSync "${logs}/${test}.log"
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

# FAM: theforeman.foreman.registration_command
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
number_container_hosts="$( ansible $opts_adhoc --list-hosts container_hosts 2>/dev/null | grep -cv '^  hosts' )"
number_containers_per_container_host="$( ansible $opts_adhoc -m ansible.builtin.debug -a "var=containers_count" container_hosts[0] | awk '/    "containers_count":/ {print $NF}' )"
if (( initial_expected_concurrent_registrations > number_container_hosts )); then
    initial_concurrent_registrations_per_container_host="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
else
    initial_concurrent_registrations_per_container_host=1
fi
num_retry_forks="$(( initial_expected_concurrent_registrations / number_container_hosts ))"
prefix=48-register

for (( batch=1, remaining_containers_per_container_host=number_containers_per_container_host, total_registered=0; remaining_containers_per_container_host > 0; batch++ )); do
    if (( remaining_containers_per_container_host > initial_concurrent_registrations_per_container_host * batch )); then
        concurrent_registrations_per_container_host="$(( initial_concurrent_registrations_per_container_host * batch ))"
    else
        concurrent_registrations_per_container_host=$remaining_containers_per_container_host
    fi
    concurrent_registrations="$(( concurrent_registrations_per_container_host * number_container_hosts ))"
    (( remaining_containers_per_container_host -= concurrent_registrations_per_container_host ))
    (( total_registered += concurrent_registrations ))
    test="${prefix}-${concurrent_registrations}"

    log "Trying to register $concurrent_registrations content hosts concurrently in this batch"

    ap "${test}.log" \
      -e "size='$concurrent_registrations_per_container_host'" \
      -e "concurrent_registrations='$concurrent_registrations'" \
      -e "num_retry_forks='$num_retry_forks'" \
      -e "registration_logs='../../$logs/$prefix-container-host-client-logs'" \
      -e 're_register_failed_hosts=true' \
      -e "sat_version='$sat_version'" \
      -e "enable_iop='$enable_iop'" \
      -e "profile='$profiling_enabled'" \
      -e "registration_profile_img='$test.svg'" \
      playbooks/tests/registrations.yaml
      e Register "${logs}/${test}.log"
done
grep Register "$logs"/$prefix-*.log >"$logs/$prefix-overall.log"
e Register "$logs/$prefix-overall.log"


section 'Remote execution (ReX)'
skip_measurement=true h 58-rex-set-via-ip.log \
  'settings set --name remote_execution_connect_by_ip --value true'
skip_measurement=true a 59-rex-cleanup-know_hosts.log \
  -m ansible.builtin.shell \
  -a 'rm -rf /usr/share/foreman-proxy/.ssh/known_hosts*' \
  satellite6

job_template_ansible_default='Run Command - Ansible Default'
job_template_script_default='Run Command - Script Default'
### XXX: This doesn't work yet
# job_template_lightspeed_remediation='Run remediations based on Insights recommendations'
# lightspeed_remediation_pairs='[{"hit_id":"3db9bd47-34ef-4c67-83cf-08c57f9b0a0d","rule_id":"hardening_logging_auditd|HARDENING_LOGGING_5_AUDITD","resolution_type":"fix","resolution_id":"hardening_logging_auditd|HARDENING_LOGGING_5_AUDITD_fix"}]'

for rex_search_query in $rex_search_queries; do
    search_query="name ~ $rex_search_query"
    search_query_ssh="$search_query and $rex_search_query_ssh"
    search_query_mqtt="$search_query and $rex_search_query_mqtt"

    num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search '$search_query'" | grep -c "$rex_search_query")"
    num_matching_rex_ssh_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search '$search_query_ssh'" | grep -c "$rex_search_query")"
    num_matching_rex_mqtt_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search '$search_query_mqtt'" | grep -c "$rex_search_query")"

    test="60f-rex-ansible-date-${num_matching_rex_hosts}"
    apj $test \
      -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}: %{command}'" \
      -e "job_template='$job_template_ansible_default'" \
      -e "search_query='$search_query'" \
      -e "command='date'" \
      -e "task_timeout=$(( num_matching_rex_hosts < 1800 ? 900 : num_matching_rex_hosts / 2 ))" \
      playbooks/tests/FAM/job_invocation_create.yaml

    if (( num_matching_rex_ssh_hosts > 0 )); then
        test="61f-rex-script_ssh-date-${num_matching_rex_ssh_hosts}"
        apj $test \
          -e "description_format='${num_matching_rex_ssh_hosts} hosts - %{template_name} (ssh): %{command}'" \
          -e "job_template='$job_template_script_default'" \
          -e "search_query='$search_query_ssh'" \
          -e "command='date'" \
          -e "task_timeout=$(( num_matching_rex_ssh_hosts < 1800 ? 900 : num_matching_rex_ssh_hosts / 2 ))" \
          playbooks/tests/FAM/job_invocation_create.yaml

        test="62f-rex-katello_package_install_ssh-podman-${num_matching_rex_ssh_hosts}"
        apj $test \
          -e "description_format='${num_matching_rex_ssh_hosts} hosts - %{template_name} (ssh): %{package}'" \
          -e "feature='katello_package_install'" \
          -e "search_query='$search_query_ssh'" \
          -e "inputs='package=podman'" \
          -e "task_timeout=$(( num_matching_rex_ssh_hosts < 1800 ? 900 : num_matching_rex_ssh_hosts / 2 ))" \
          playbooks/tests/FAM/job_invocation_create.yaml
    fi  # num_matching_rex_hosts > 0

    if (( num_matching_rex_mqtt_hosts > 0 )); then
        test="61f-rex-script_mqtt-date-${num_matching_rex_mqtt_hosts}"
        apj $test \
          -e "description_format='${num_matching_rex_mqtt_hosts} hosts - %{template_name} (mqtt): %{command}'" \
          -e "job_template='$job_template_script_default'" \
          -e "search_query='$search_query_mqtt'" \
          -e "command='date'" \
          -e "task_timeout=$(( num_matching_rex_mqtt_hosts < 1800 ? 900 : num_matching_rex_mqtt_hosts / 2 ))" \
          playbooks/tests/FAM/job_invocation_create.yaml

        test="62f-rex-katello_package_install_mqtt-podman-${num_matching_rex_mqtt_hosts}"
        apj $test \
          -e "description_format='${num_matching_rex_mqtt_hosts} hosts - %{template_name} (mqtt): %{package}'" \
          -e "feature='katello_package_install'" \
          -e "search_query='$search_query_mqtt'" \
          -e "inputs='package=podman'" \
          -e "task_timeout=$(( num_matching_rex_mqtt_hosts < 1800 ? 900 : num_matching_rex_mqtt_hosts / 2 ))" \
          playbooks/tests/FAM/job_invocation_create.yaml
    fi  # num_matching_rex_mqtt_hosts > 0
    
    test="63f-rex-ansible-podman_login_pull_rhosp-${num_matching_rex_hosts}"
    apj $test \
      -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}: %{command}'" \
      -e "job_template='$job_template_ansible_default'" \
      -e "search_query='$search_query'" \
      -e "command='bash -x /root/podman-login.sh && bash -x /root/podman-pull-rhosp.sh'" \
      -e "task_timeout=$(( num_matching_rex_hosts < 1800 ? 900 : num_matching_rex_hosts / 2 ))" \
      playbooks/tests/FAM/job_invocation_create.yaml

    if vercmp_ge "$sat_version" '6.17.0'; then
        if $enable_iop; then
            test="65f-rex-ansible-insigths-client-${num_matching_rex_hosts}"
            apj $test \
              -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}: %{command}'" \
              -e "job_template='$job_template_ansible_default'" \
              -e "search_query='$search_query'" \
              -e "command='insights-client'" \
              -e "task_timeout=$(( num_matching_rex_hosts < 1800 ? 900 : num_matching_rex_hosts / 2 ))" \
              playbooks/tests/FAM/job_invocation_create.yaml
            
            # if vercmp_ge "$sat_version" '6.18.0'; then
            #     test="66f-rex-apply_remediation-${num_matching_rex_hosts}"
            #     apj $test \
            #       -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}'" \
            #       -e "job_template='$job_template_lightspeed_remediation'" \
            #       -e "search_query='$search_query'" \
            #       -e "inputs=hit_remediation_pairs='$lightspeed_remediation_pairs'" \
            #       -e "task_timeout=$(( num_matching_rex_hosts < 1800 ? 900 : num_matching_rex_hosts / 2 ))" \
            #       playbooks/tests/FAM/job_invocation_create.yaml
            # fi  # vercmp_ge "$sat_version" '6.18.0'
        fi  # $enable_iop
    fi  # vercmp_ge "$sat_version" '6.17.0'

    if (( num_matching_rex_ssh_hosts > 0 )); then
        test="69f-rex-katello_package_update_ssh-${num_matching_rex_ssh_hosts}"
        apj $test \
          -e "description_format='${num_matching_rex_ssh_hosts} hosts - %{template_name} (ssh)'" \
          -e "feature='katello_package_update'" \
          -e "search_query='$search_query_ssh'" \
          -e "task_timeout=$(( num_matching_rex_ssh_hosts < 1800 ? 900 : num_matching_rex_ssh_hosts / 2 ))" \
          playbooks/tests/FAM/job_invocation_create.yaml
    fi  # num_matching_rex_ssh_hosts > 0

    if (( num_matching_rex_mqtt_hosts > 0 )); then
        test="69f-rex-katello_package_update_mqtt-${num_matching_rex_mqtt_hosts}"
        apj $test \
          -e "description_format='${num_matching_rex_mqtt_hosts} hosts - %{template_name} (mqtt)'" \
          -e "feature='katello_package_update'" \
          -e "search_query='$search_query_mqtt'" \
          -e "task_timeout=$(( num_matching_rex_mqtt_hosts < 1800 ? 900 : num_matching_rex_mqtt_hosts / 2 ))" \
          playbooks/tests/FAM/job_invocation_create.yaml
    fi  # num_matching_rex_mqtt_hosts > 0
done

rex_search_query=container
search_query="name ~ $rex_search_query"
num_matching_rex_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search '$search_query'" | grep -c "$rex_search_query")"

if $enable_iop; then
    test="65f-rex-ansible-insigths-client-${num_matching_rex_hosts}"
    apj $test \
      -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}: %{command}'" \
      -e "job_template='$job_template_ansible_default'" \
      -e "search_query='$search_query'" \
      -e "command='insights-client'" \
      -e "task_timeout=$(( num_matching_rex_hosts / 2 ))" \
      playbooks/tests/FAM/job_invocation_create.yaml
fi


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

h "99-task_list-running-before_backup.log" \
      "--no-headers --csv task list --organization-id 1 --search 'state = running and result = pending'"


if vercmp_ge "$sat_version" '6.17.0'; then
    if $enable_iop; then
        section 'Generate rh_cloud_inventory report'
        a 53-foreman_inventory_upload-report-generate.log \
          -m ansible.builtin.shell \
          -a "export organization='{{ sat_org }}'; export target=/var/lib/foreman/red_hat_inventory/generated_reports/; /usr/sbin/foreman-rake rh_cloud_inventory:report:generate" \
          satellite6
    fi

    section 'Generate satellite-maintain report'
    as 95-satellite-maintain_report_generate.log \
      'satellite-maintain report generate'
fi


section 'Backup'
test=99-backup
ap "${test}.log" \
  -e "sat_version='$sat_version'" \
  playbooks/tests/sat-backup.yaml
e BackupOffline "${logs}/${test}.log"
e RestoreOffline "${logs}/${test}.log"
e BackupOnline "${logs}/${test}.log"
e RestoreOnline "${logs}/${test}.log"


section 'Delete all content hosts'
test=99-remove-hosts-if-any
ap "${test}.log" \
  playbooks/satellite/satellite-remove-hosts.yaml


section 'Delete base LCE(s), CCV(s) and AK(s)'
index_ten=10

# Delete AKs
activation_keys="$(echo "$activation_keys" |
  jq -c \
  'map(. + {"state": "absent"})')"

test="${index_ten}1fr-ak-delete"
apj $test \
  -e "activation_keys='$activation_keys'" \
  playbooks/tests/FAM/activation_keys.yaml

# Delete CCVs/CVs
content_views="$(echo $content_views |
  jq -c \
  'map(. + {"state": "absent"}) |
  sort')"

test="${index_ten}2fr-cv-delete"
apj $test \
  -e "content_views='$content_views'" \
  playbooks/tests/FAM/content_views.yaml

# Delete LCEs
lifecycle_environments="$(echo "$lifecycle_environments" |
  jq -c \
  'map(. + {"state": "absent"})')"

test="${index_ten}3fr-lce-delete"
apj $test \
  -e "lifecycle_environments='$lifecycle_environments'" \
  playbooks/tests/FAM/lifecycle_environments.yaml

# Repository deletion
for rid in $rids; do
    h "103-repository-delete-${rid}.log" \
      "repository delete --organization '{{ sat_org }}' --name '$rid'"
done

# Product deletion
# Satellite Client
h 104-product-delete-sat-client.log \
  "product delete --organization '{{ sat_org }}' --name '$sat_client_product'"
# RHOSP
h "104-product-delete-${rhosp_product}.log" \
  "product delete --organization '{{ sat_org }}' --name '$rhosp_product'"
if vercmp_ge "$sat_version" '6.17.0'; then
    # Flatpak
    h "104-product-delete-${flatpak_product}.log" \
      "product delete --organization '{{ sat_org }}' --name '$flatpak_product'"
fi


section 'Sosreport'
ap sosreporter-gatherer.log \
  -e "sosreport_gatherer_local_dir='../../$logs/sosreport/'" \
  playbooks/satellite/sosreport_gatherer.yaml


junit_upload
