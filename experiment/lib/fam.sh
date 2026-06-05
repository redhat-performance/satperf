#!/bin/bash
# FAM section functions — sourced by full_fam.sh and other experiment scripts.
# Functions using theforeman.foreman collection (apj + playbooks/tests/FAM/).
# Suffixed with _fam so callers can switch from hammer to FAM per-section.

create_lces_fam() {
    lces="${PARAM_lces:-Test QA Pre Prod}"
    lces_comma="$(echo "$lces" | tr ' ' ',')"

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
    done # for lce in $lces

    test=01fr-lce-create
    apj $test \
        -e "lifecycle_environments='$lifecycle_environments'" \
        playbooks/tests/FAM/lifecycle_environments.yaml

} # create_lces_fam

prepare_rh_content_fam() {
    manifest_exercise_runs="${PARAM_manifest_exercise_runs:-0}"

    section 'Prepare for Red Hat content'
    if ((manifest_exercise_runs > 0)); then
        test=09f-manifest-exercise
        skip_measurement=true apj $test \
            -e "runs='$manifest_exercise_runs'" \
            playbooks/tests/FAM/manifest_test.yaml
        ej ManifestImport $test &
        ej ManifestRefresh $test &
        ej ManifestDelete $test &
    fi

    test=09f-manifest-import
    skip_measurement=true apj $test \
        playbooks/tests/FAM/manifest_import.yaml

    # Get content
    settings="$(jq -cn \
        '[{"name": "foreman_proxy_content_auto_sync", "value": "false"}]')"

    test=00fr-settings-foreman_proxy_content_auto_sync
    skip_measurement=true apj $test \
        -e "settings='$settings'" \
        playbooks/tests/FAM/settings.yaml

    products='[]'
    content_views='[]'
    activation_keys='[]'

} # prepare_rh_content_fam

push_product_fam() {
    local product=$1
    local product_code
    product_code="$(echo "$product" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"

    section "Push $product content to capsules"
    local index_ten
    case "$product" in
    "$rhel_product")
        index_ten=1
        ;;
    "$sat_client_product")
        index_ten=2
        ;;
    "$rhosp_product")
        index_ten=3
        ;;
    "$flatpak_product")
        index_ten=4
        ;;
    esac

    if ((num_capsules > 0)); then
        local test="${index_ten}9-capsules-sync-${product_code}"
        ap "${test}.log" \
            -e "lces='$lces'" \
            playbooks/tests/FAM/capsule_sync.yaml
        e CapsuleSync "${logs}/${test}.log"
    fi # num_capsules > 0
} # push_product_fam

fetch_product_fam() {
    local product=$1

    section "Get $product content"
    product_code="$(echo $product | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"
    product_underscore="$(echo $product | tr ' ' '_')"
    product_products='[]'

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
    esac # "$product"

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
        # We don't want to measure it because it's fake
        skip_measurement=true apj $test \
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
    fi # "$product" == "$flatpak_product"

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
                ;;
            esac # "$rel_num"

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
        else # "$product" != "$rhel_product"
            product_repositories='[]'

            case "$product" in
            $sat_client_product)
                repo_name="$product for RHEL $rel_num"
                repo_url="${repo_sat_client}/Satellite_Client_RHEL${rel_num}_${basearch}/"
                ;;
            $flatpak_product)
                case "$rel_num" in
                [8-9] | 10)
                    # product_code_rel_num="${product_code}_${rel_num}"
                    product_underscore="$(echo $product | tr ' ' '_')"

                    flatpak_packages='flatpak-runtime flatpak-sdk'
                    (("$rel_num" == 10)) && flatpak_packages+=' firefox-flatpak thunderbird-flatpak'

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
                    done # for package in $flatpak_packages
                    ;;
                *)
                    continue
                    ;;
                esac # "$rel_num"
                ;;
            esac # "$product"

            if [[ "$product" == "$sat_client_product" ]]; then
                product_repositories="$(echo "$product_repositories" |
                    jq -c \
                        --arg name "$repo_name" \
                        --arg url "$repo_url" \
                        --arg content_type "$content_type" \
                        '. += [{"name": $name, "url": $url, "content_type": $content_type}]')"

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
            fi # "$product" == "$sat_client_product"
        fi  # "$product"
    done # for rel in $rels

    if [[ "$product" == "$rhosp_product" ]]; then
        product_repositories='[]'

        for rhosp_repo_name in "${rhosp_repo_names[@]}"; do
            product_repositories="$(echo "$product_repositories" |
                jq -c \
                    --arg name "$rhosp_repo_name" \
                    --arg content_type "$content_type" \
                    --arg url "$rhosp_registry_url" \
                    --arg docker_upstream_name "$rhosp_repo_name" \
                    --arg upstream_username "$rhosp_registry_username" \
                    --arg upstream_password "$rhosp_registry_password" \
                    '. += [{"name": $name, "content_type": $content_type, "url": $url, "docker_upstream_name": $docker_upstream_name, "upstream_username": $upstream_username, "upstream_password": $upstream_password}]')"
        done

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
    fi # "$product" == "$rhosp_product"

    products="$(echo "$products" | jq -c \
        --argjson product_products "$product_products" \
        '. + $product_products')"

    # Set $product repositories (skip for flatpak — already created above)
    if [[ "$product" != "$flatpak_product" ]]; then
        test="${index_ten}0fr-product-create-${product_code}"
        apj $test \
            -e "products='$product_products'" \
            playbooks/tests/FAM/repositories.yaml
    fi

    # Sync $product products
    echo "$product_products" | jq -r '.[].name' | while read product; do
        product_code="$(echo $product | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"

        test="${index_ten}4f-product-sync-${product_code}"
        apj $test \
            -e "product='$product'" \
            playbooks/tests/FAM/repo_sync.yaml
    done # while read product

    section "Create $product CVs/CCVs"

    if [[ "$product" == "$rhosp_product" ]]; then
        # Build single shared CV_rhosp with all repos (not per-rel)
        cv_rhosp="CV_${product_code}"
        rhosp_product_repositories='[]'

        for rhosp_repo_name in "${rhosp_repo_names[@]}"; do
            rhosp_product_repositories="$(echo "$rhosp_product_repositories" |
                jq -c \
                    --arg name "$rhosp_repo_name" \
                    --arg product "$product" \
                    '. + [{"name": $name, "product": $product}]')"
        done

        content_views="$(echo "$content_views" |
            jq -c \
                --arg name "$cv_rhosp" \
                --argjson repositories "$rhosp_product_repositories" \
                '. + [{"name": $name, "repositories": $repositories}]')"
    fi # "$product" == "$rhosp_product"

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
            esac # "$rel_num"
        else  # "$product" != "$rhel_product"
            case "$product" in
            $sat_client_product)
                repo_name="$product for RHEL $rel_num"
                repo_name_code="$(echo ${repo_name} | tr ' ' '_' | tr '/' '_')"
                organization_underscore="$(echo $organization | tr ' ' '_')"
                content_label="${organization_underscore}_${product_underscore}_${repo_name_code}"
                content_overrides='[]'
                ;;
            $flatpak_product)
                case "$rel_num" in
                [8-9] | 10)
                    flatpak_packages='flatpak-runtime flatpak-sdk'
                    (("$rel_num" == 10)) && flatpak_packages+=' firefox-flatpak thunderbird-flatpak'

                    for package in $flatpak_packages; do
                        repo_name="${rel}/${package}"
                        repo_name_code="$(echo ${repo_name} | tr ' ' '_' | tr '/' '_')"

                        product_repositories="$(echo "$product_repositories" |
                            jq -c \
                                --arg name "$repo_name" \
                                --arg product "$product" \
                                '. + [{"name": $name, "product": $product}]')"
                    done # for package in $flatpak_packages
                    ;;
                *)
                    continue
                    ;;
                esac # "$rel_num"
                ;;
            esac # "$product"

            if [[ "$product" != "$flatpak_product" && "$product" != "$rhosp_product" ]]; then
                product_repositories="$(echo "$product_repositories" |
                    jq -c \
                        --arg name "$repo_name" \
                        --arg product "$product" \
                        '. + [{"name": $name, "product": $product}]')"
            fi # "$product" != "$flatpak_product" && "$product" != "$rhosp_product"
        fi  # "$product" == "$rhel_product"

        # CV
        if [[ "$product" != "$rhosp_product" ]]; then
            cv="CV_${product_code_rel_num}"
            content_views="$(echo "$content_views" |
                jq -c \
                    --arg name "$cv" \
                    --argjson repositories "$product_repositories" \
                    '. + [{"name": $name, "repositories": $repositories}]')"
        else # "$product" == "$rhosp_product"
            cv="CV_${product_code}"
        fi # "$product" != "$rhosp_product"

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
            done # for lce in $lces
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
            done # for lce in $lces
        fi    # "$product" != "$sat_client_product"
    done   # for rel in $rels

    product_content_views="$(echo "$content_views" |
        jq -c \
            --arg product_code "CV_${product_code}" \
            'map(select(.repositories and (.name | startswith($product_code))))')"

    # Create $product CVs
    test="${index_ten}5fr-cv-create-${product_code}"
    apj $test \
        -e "content_views='$product_content_views'" \
        playbooks/tests/FAM/content_views.yaml

    # Publish $product CVs
    test="${index_ten}5fr-cv-publish-${product_code}"
    ap "${test}.log" \
        -e "content_views='$product_content_views'" \
        playbooks/tests/FAM/cv_publish.yaml
    e ContentViewPublish "${logs}/${test}.log"

} # fetch_product_fam

get_base_content_fam() {
    rels="${PARAM_rels:-rhel7 rhel8 rhel9 rhel10}"
    basearch=x86_64

    rhel_product="${rhel_product:-RHEL}"
    sat_client_product="${sat_client_product:-Satellite Client}"
    repo_sat_client="${PARAM_repo_sat_client:-http://mirror.example.com}"
    rhosp_product="${rhosp_product:-RHOSP}"
    rhosp_registry_url="${rhosp_registry_url:-https://${PARAM_rhosp_registry:-registry.example.io}}"
    rhosp_registry_username="${PARAM_rhosp_registry_username:-user}"
    rhosp_registry_password="${PARAM_rhosp_registry_password:-password}"
    if [[ ${#rhosp_repo_names[@]} -eq 0 ]]; then
        rhosp_repo_names=(
            rhoso/openstack-base-rhel9
            rhoso/openstack-neutron-server-rhel9
            rhoso/openstack-nova-api-rhel9
            rhoso/openstack-nova-compute-rhel9
        )
    fi

    if ((${#tested_products[@]} == 0)); then
        tested_products=("$rhel_product" "$sat_client_product" "$rhosp_product")
        if vercmp_ge "$sat_version" '6.17.0'; then
            flatpak_product="${flatpak_product:-Flatpak}"
            flatpak_remote="${flatpak_remote:-rhel}"
            flatpak_remote_url="${flatpak_remote_url:-https://${PARAM_flatpak_remote:-flatpak.example.io}}"
            flatpak_remote_username="${PARAM_flatpak_remote_username:-user}"
            flatpak_remote_password="${PARAM_flatpak_remote_password:-password}"
            tested_products+=("$flatpak_product")
        fi
    fi
    [[ -n "${PARAM_tested_products:-}" ]] && read -ra tested_products <<<"$PARAM_tested_products"

    num_capsules="$(get_num_hosts capsules)"

    # 1. Fetch and publish per-product CVs
    for product in "${tested_products[@]}"; do
        fetch_product_fam "$product"
    done

    # 2. Create, publish, promote CCVs (once, with all product components)
    section 'Create, publish and promote CCVs'
    composite_content_views="$(echo "$content_views" | jq -c 'map(select(.components))')"

    test=55fr-ccv-create
    apj $test \
        -e "content_views='$composite_content_views'" \
        playbooks/tests/FAM/content_views.yaml

    test=55fr-ccv-publish
    ap "${test}.log" \
        -e "content_views='$composite_content_views'" \
        playbooks/tests/FAM/cv_publish.yaml
    e ContentViewPublish "${logs}/${test}.log"

    test=56f-ccv-version-promote
    ap "${test}.log" \
        -e "content_views='$composite_content_views'" \
        -e "lifecycle_environments='$lces_comma'" \
        playbooks/tests/FAM/cv_version_promote.yaml
    e ContentViewVersionPromote "${logs}/${test}.log"

    # 3. Create/update AKs (all CCVs now promoted to LCEs)
    test=57fr-ak-create_update
    apj $test \
        -e "activation_keys='$activation_keys'" \
        playbooks/tests/FAM/activation_keys.yaml

    # 4. Push all content to capsules (CVs + CCVs, once)
    if ((num_capsules > 0)); then
        for product in "${tested_products[@]}"; do
            push_product_fam "$product"
        done
    fi

} # get_base_content_fam

create_bench_cvs_fam() {
    section 'Create, publish and promote big CV'
    product_code=Bench
    index_ten=6

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
        esac # "$rel_num"
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
            'map(select(.repositories and (.name | test($product_code))))')"

    # Create $product_code CV
    test="${index_ten}5fr-cv-create-big-${product_code}"
    apj $test \
        -e "content_views='$product_content_views'" \
        playbooks/tests/FAM/content_views.yaml

    # Publish $product_code CV
    test="${index_ten}5fr-cv-publish-big-${product_code}"
    ap "${test}.log" \
        -e "content_views='$product_content_views'" \
        playbooks/tests/FAM/cv_publish.yaml
    e ContentViewPublish "${logs}/${test}.log"

    # Promote $product_code CV
    test="${index_ten}6f-cv-version-promote-big-${cv}"
    # apj $test \
    #   -e "cv='$cv'" \
    #   -e "current_lifecycle_environment=Library" \
    #   -e "lifecycle_environments='$lces_comma'" \
    #   playbooks/tests/FAM/cv_version_promote.yaml
    ap "${test}.log" \
        -e "content_views='$product_content_views'" \
        -e "lifecycle_environments='$lces_comma'" \
        playbooks/tests/FAM/cv_version_promote.yaml
    e ContentViewVersionPromote "${logs}/${test}.log"

    section 'Create, publish and promote filtered CV'
    product_code=BenchFiltered
    index_ten=7

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
            'map(select(.repositories and (.name | test($product_code))))')"

    # Create $product_code CV
    test="${index_ten}6fr-cv-create-filtered-${product_code}"
    apj $test \
        -e "content_views='$product_content_views'" \
        playbooks/tests/FAM/content_views.yaml

    # Publish $product_code CV
    test="${index_ten}5fr-cv-publish-filtered-${product_code}"
    ap "${test}.log" \
        -e "content_views='$product_content_views'" \
        playbooks/tests/FAM/cv_publish.yaml
    e ContentViewPublish "${logs}/${test}.log"

    # Promote $product_code CV
    test="${index_ten}6f-cv-version-promote-filtered-${cv}"
    # apj $test \
    #   -e "cv='$cv'" \
    #   -e "current_lifecycle_environment=Library" \
    #   -e "lifecycle_environments='$lces_comma'" \
    #   playbooks/tests/FAM/cv_version_promote.yaml
    ap "${test}.log" \
        -e "content_views='$product_content_views'" \
        -e "lifecycle_environments='$lces_comma'" \
        playbooks/tests/FAM/cv_version_promote.yaml
    e ContentViewVersionPromote "${logs}/${test}.log"

} # create_bench_cvs_fam

prepare_registrations_fam() {
    lces="${PARAM_lces:-Test QA Pre Prod}"
    rels="${PARAM_rels:-rhel7 rhel8 rhel9 rhel10}"

    section 'Prepare for registrations'
    unset aks
    for rel in $rels; do
        rel_num="${rel##rhel}"

        for lce in $lces; do
            ak="AK_${rel_num}_${lce}"
            aks="${aks:+$aks }$ak"
        done
    done

    test=44f-registration-command-generate
    apj $test \
        -e "aks='$aks'" \
        -e "sat_version='$sat_version'" \
        -e "enable_iop=$enable_iop" \
        playbooks/tests/FAM/registration_command_generate.yaml

    ap 44-recreate-client-scripts.log \
        -e "aks='$aks'" \
        -e "sat_version='$sat_version'" \
        playbooks/tests/client-scripts.yaml

} # prepare_registrations_fam

remote_execution_fam() {
    rex_search_queries="${PARAM_rex_search_queries:-container110 container10 container0}"
    rex_search_query_ssh="${PARAM_rex_search_query_ssh:-(name ~ ssh)}"
    rex_search_query_mqtt="${PARAM_rex_search_query_mqtt:-(name ~ mqtt)}"

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

        ((num_matching_rex_hosts > 0)) || continue

        num_matching_rex_ssh_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search '$search_query_ssh'" | grep -c "$rex_search_query")"
        num_matching_rex_mqtt_hosts="$(h_out "--no-headers --csv host list --organization '{{ sat_org }}' --thin true --search '$search_query_mqtt'" | grep -c "$rex_search_query")"

        test="60f-rex-ansible-date-${num_matching_rex_hosts}"
        apj $test \
            -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}: %{command}'" \
            -e "job_template='$job_template_ansible_default'" \
            -e "search_query='$search_query'" \
            -e "command='date'" \
            -e "task_timeout=$((num_matching_rex_hosts < 450 ? 450 : num_matching_rex_hosts))" \
            playbooks/tests/FAM/job_invocation_create.yaml
        ejji $test

        if ((num_matching_rex_ssh_hosts > 0)); then
            test="61f-rex-script_ssh-date-${num_matching_rex_ssh_hosts}"
            apj $test \
                -e "description_format='${num_matching_rex_ssh_hosts} hosts - %{template_name} (ssh): %{command}'" \
                -e "job_template='$job_template_script_default'" \
                -e "search_query='$search_query_ssh'" \
                -e "command='date'" \
                -e "task_timeout=$((num_matching_rex_ssh_hosts < 450 ? 450 : num_matching_rex_ssh_hosts))" \
                playbooks/tests/FAM/job_invocation_create.yaml
            ejji $test

            test="62f-rex-katello_package_install_ssh-rust-${num_matching_rex_ssh_hosts}"
            apj $test \
                -e "description_format='${num_matching_rex_ssh_hosts} hosts - %{template_name} (ssh): %{package}'" \
                -e "feature='katello_package_install'" \
                -e "search_query='$search_query_ssh'" \
                -e "inputs='package=rust'" \
                -e "task_timeout=$((num_matching_rex_ssh_hosts < 450 ? 450 : num_matching_rex_ssh_hosts))" \
                playbooks/tests/FAM/job_invocation_create.yaml
            ejji $test
        fi # num_matching_rex_ssh_hosts > 0

        if ((num_matching_rex_mqtt_hosts > 0)); then
            test="61f-rex-script_mqtt-date-${num_matching_rex_mqtt_hosts}"
            apj $test \
                -e "description_format='${num_matching_rex_mqtt_hosts} hosts - %{template_name} (mqtt): %{command}'" \
                -e "job_template='$job_template_script_default'" \
                -e "search_query='$search_query_mqtt'" \
                -e "command='date'" \
                -e "task_timeout=$((num_matching_rex_mqtt_hosts < 450 ? 900 : num_matching_rex_mqtt_hosts * 2))" \
                playbooks/tests/FAM/job_invocation_create.yaml
            ejji $test

            test="62f-rex-katello_package_install_mqtt-rust-${num_matching_rex_mqtt_hosts}"
            apj $test \
                -e "description_format='${num_matching_rex_mqtt_hosts} hosts - %{template_name} (mqtt): %{package}'" \
                -e "feature='katello_package_install'" \
                -e "search_query='$search_query_mqtt'" \
                -e "inputs='package=rust'" \
                -e "task_timeout=$((num_matching_rex_mqtt_hosts < 450 ? 900 : num_matching_rex_mqtt_hosts * 2))" \
                playbooks/tests/FAM/job_invocation_create.yaml
            ejji $test
        fi # num_matching_rex_mqtt_hosts > 0

        # if $enable_iop && vercmp_ge "$sat_version" '6.18.0'; then
        #     test="66f-rex-apply_remediation-${num_matching_rex_hosts}"
        #     apj $test \
        #       -e "description_format='${num_matching_rex_hosts} hosts - %{template_name}'" \
        #       -e "job_template='$job_template_lightspeed_remediation'" \
        #       -e "search_query='$search_query'" \
        #       -e "inputs=hit_remediation_pairs='$lightspeed_remediation_pairs'" \
        #       -e "task_timeout=$(( num_matching_rex_hosts < 450 ? 900 : num_matching_rex_hosts * 2 ))" \
        #       playbooks/tests/FAM/job_invocation_create.yaml
        #     ejji $test
        # fi  # $enable_iop && vercmp_ge "$sat_version" '6.18.0'

        if ((num_matching_rex_ssh_hosts > 0)); then
            test="69f-rex-katello_package_update_ssh-${num_matching_rex_ssh_hosts}"
            apj $test \
                -e "description_format='${num_matching_rex_ssh_hosts} hosts - %{template_name} (ssh)'" \
                -e "feature='katello_package_update'" \
                -e "search_query='$search_query_ssh'" \
                -e "task_timeout=$((num_matching_rex_ssh_hosts < 450 ? 900 : num_matching_rex_ssh_hosts * 2))" \
                playbooks/tests/FAM/job_invocation_create.yaml
            ejji $test
        fi # num_matching_rex_ssh_hosts > 0

        if ((num_matching_rex_mqtt_hosts > 0)); then
            test="69f-rex-katello_package_update_mqtt-${num_matching_rex_mqtt_hosts}"
            apj $test \
                -e "description_format='${num_matching_rex_mqtt_hosts} hosts - %{template_name} (mqtt)'" \
                -e "feature='katello_package_update'" \
                -e "search_query='$search_query_mqtt'" \
                -e "task_timeout=$((num_matching_rex_mqtt_hosts < 450 ? 1350 : num_matching_rex_mqtt_hosts * 3))" \
                playbooks/tests/FAM/job_invocation_create.yaml
            ejji $test
        fi # num_matching_rex_mqtt_hosts > 0
    done

    # ReX cleanup
    task_label='Actions::RemoteExecution::RunHostsJob'

    test=69f-kill-rex-jobs
    skip_measurement=true ap "${test}.log" \
        -e "task_label='$task_label'" \
        playbooks/tests/FAM/kill_pending_tasks.yaml

} # remote_execution_fam

cleanup_fam() {

    section 'Delete all content hosts'
    test=999-remove-hosts-if-any
    ap "${test}.log" \
        playbooks/satellite/satellite-remove-hosts.yaml

    section 'Delete base LCE(s), CCV(s) and AK(s)'
    index_ten=100

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

    # Product deletion
    products="$(echo "$products" | jq -c \
        'map({"name": .name, "state": "absent"})')"

    test="${index_ten}4fr-product-delete"
    apj $test \
        -e "products='$products'" \
        playbooks/tests/FAM/repositories.yaml

} # cleanup_fam

setup_rolling_repos_fam() {
    local cv_rolling_product="${PARAM_cv_rolling_product:-BenchRollingProduct}"
    local cv_rolling_repo_count="${PARAM_cv_rolling_repo_count:-2}"
    local cv_rolling_repo_url_template="${PARAM_test_sync_repositories_url_template:-http://repos.example.com/repo*}"

    section 'Create product with custom yum repos for rolling CV test'
    product_repositories='[]'
    for i in $(seq 1 "$cv_rolling_repo_count"); do
        repo_name="bench_rolling_repo${i}"
        repo_url="$(echo "$cv_rolling_repo_url_template" | sed "s/\*/$i/")"
        product_repositories="$(echo "$product_repositories" |
          jq -c \
           --arg name "$repo_name" \
           --arg url "$repo_url" \
           --arg content_type "yum" \
           '. += [{"name": $name, "url": $url, "content_type": $content_type}]')"
    done

    products="$(jq -cn \
       --arg name "$cv_rolling_product" \
       --argjson repositories "$product_repositories" \
       '[{"name": $name, "repositories": $repositories}]')"

    test=95fr-product-create-rolling
    skip_measurement=true apj $test \
      -e "products='$products'" \
      playbooks/tests/FAM/repositories.yaml

    section 'Initial repo sync'
    test=96fr-repo-sync-rolling-initial
    apj $test \
      -e "product='$cv_rolling_product'" \
      playbooks/tests/FAM/repo_sync.yaml

    # Build repo references for rolling CVs (global for rolling_cv_scaling_fam)
    cv_rolling_repos='[]'
    for i in $(seq 1 "$cv_rolling_repo_count"); do
        repo_name="bench_rolling_repo${i}"
        cv_rolling_repos="$(echo "$cv_rolling_repos" |
            jq -c \
                --arg name "$repo_name" \
                --arg product "$cv_rolling_product" \
                '. += [{"name": $name, "product": $product}]')"
    done
} # setup_rolling_repos_fam

rolling_cv_scaling_fam() {
    if ! vercmp_ge "$sat_version" '6.18.0'; then
        echo "Skipping rolling CV tests: requires Satellite >= 6.18.0 (got $sat_version)"
        return 0
    fi

    local cv_rolling_product="${PARAM_cv_rolling_product:-BenchRollingProduct}"
    local cv_rolling_count="${PARAM_cv_rolling_count:-100}"
    local cv_rolling_batch_size="${PARAM_cv_rolling_batch_size:-10}"
    local cv_rolling_prefix="${PARAM_cv_rolling_prefix:-BenchRollingCV}"

    section 'Baseline sync (0 rolling CVs)'
    test=97fr-sync-baseline-0-rolling-cvs
    ap "${test}.log" \
      -e "product='$cv_rolling_product'" \
      playbooks/tests/FAM/repo_sync.yaml
    e ProductSync "${logs}/${test}.log"

    section 'Create rolling CVs in batches and measure sync after each'
    for (( batch_start=1; batch_start<=cv_rolling_count; batch_start+=cv_rolling_batch_size )); do
        batch_end=$((batch_start + cv_rolling_batch_size - 1))
        if (( batch_end > cv_rolling_count )); then
            batch_end=$cv_rolling_count
        fi

        for (( i=batch_start; i<=batch_end; i++ )); do
            cv="${cv_rolling_prefix}${i}"
            test="98fr-cv-create-rolling-${cv}"
            apj $test \
              -e "cv='$cv'" \
              -e "repositories='$cv_rolling_repos'" \
              -e "lifecycle_environments='Library'" \
              playbooks/tests/FAM/cv_rolling_create.yaml
        done

        test="99fr-sync-with-${batch_end}-rolling-cvs"
        ap "${test}.log" \
          -e "product='$cv_rolling_product'" \
          playbooks/tests/FAM/repo_sync.yaml
        e ProductSync "${logs}/${test}.log"
    done
} # rolling_cv_scaling_fam

incremental_cv_updates_fam() {
    # SAT-31208: Baseline timing for incremental CV updates with ~8 repos,
    # filters enabled, no dependency solving.
    #
    # Creates CV_IncrementalBench with BaseOS+AppStream for each release in
    # $rels, plus an erratum inclusion filter. Publishes, promotes, then
    # runs one incremental update per erratum to measure each independently.
    #
    # Default errata (one per RHEL release):
    #   RHEL 7:  RHSA-2024:2002  (grub2, pre-EOS, Server repo)
    #   RHEL 8:  RHSA-2025:1372  (podman/buildah, ~20 packages, AppStream)
    #   RHEL 9:  RHSA-2025:17742 (vim, ~6 packages, BaseOS)
    #   RHEL 10: RHSA-2025:20126 (openssh, ~7 packages, BaseOS)
    rels="${PARAM_rels:-rhel7 rhel8 rhel9 rhel10}"
    basearch="${PARAM_basearch:-x86_64}"
    local cv_name="${PARAM_cv_incremental:-CV_IncrementalBench}"
    local cv_lce="${PARAM_cv_incremental_lces:-IncrementalBenchLifeEnv}"

    section 'Create LCE for incremental CV'
    local lifecycle_environments
    lifecycle_environments="$(jq -cn \
       --arg name "$cv_lce" \
       --arg prior 'Library' \
       '[{"name": $name, "prior": $prior}]')"

    test=90fr-lce-create-incremental
    apj $test \
      -e "lifecycle_environments='$lifecycle_environments'" \
      playbooks/tests/FAM/lifecycle_environments.yaml

    section 'Create incremental CV with filters (RHEL repos for configured releases)'
    local repositories='[]'

    for rel in $rels; do
        rel_num="${rel##rhel}"

        case "$rel_num" in
        7)
            product_name='Red Hat Enterprise Linux Server'

            repo_name="Red Hat Enterprise Linux $rel_num Server RPMs $basearch ${rel_num}Server"
            repositories="$(echo "$repositories" |
              jq -c \
                --arg name "$repo_name" \
                --arg product "$product_name" \
                '. + [{"product": $product, "name": $name}]')"

            # Extras
            repo_name="Red Hat Enterprise Linux $rel_num Server - Extras RPMs $basearch"
            repositories="$(echo "$repositories" |
              jq -c \
                --arg name "$repo_name" \
                --arg product "$product_name" \
                '. + [{"product": $product, "name": $name}]')"
            ;;
        *)
            product_name="Red Hat Enterprise Linux for $basearch"

            # BaseOS
            repo_name="Red Hat Enterprise Linux $rel_num for $basearch - BaseOS RPMs $rel_num"
            repositories="$(echo "$repositories" |
              jq -c \
                --arg name "$repo_name" \
                --arg product "$product_name" \
                '. + [{"product": $product, "name": $name}]')"

            # AppStream
            repo_name="Red Hat Enterprise Linux $rel_num for $basearch - AppStream RPMs $rel_num"
            repositories="$(echo "$repositories" |
              jq -c \
                --arg name "$repo_name" \
                --arg product "$product_name" \
                '. + [{"product": $product, "name": $name}]')"
            ;;
        esac
    done

    local cv_content_views
    cv_content_views="$(jq -cn \
       --arg name "$cv_name" \
       --argjson repositories "$repositories" \
       '[{"name": $name, "repositories": $repositories,
          "filters": [{"name": "IncrementalBenchFilter", "filter_type": "erratum",
                       "inclusion": "true"}]}]')"

    test=91fr-cv-create-incremental
    apj $test \
      -e "content_views='$cv_content_views'" \
      playbooks/tests/FAM/content_views.yaml

    local cv_publish_list
    cv_publish_list="$(jq -cn --arg name "$cv_name" '[{"name": $name}]')"

    test=92fr-cv-publish-incremental
    apj $test \
      -e "content_views='$cv_publish_list'" \
      playbooks/tests/FAM/cv_publish.yaml

    test=93f-cv-version-promote-incremental
    apj $test \
      -e "content_views='$cv_publish_list'" \
      -e "lifecycle_environments='$cv_lce'" \
      playbooks/tests/FAM/cv_version_promote.yaml

    section 'Incremental content view updates (one erratum per release)'
    for rel in $rels; do
        rel_num="${rel##rhel}"

        case "$rel_num" in
        7)  erratum="${PARAM_cv_incremental_erratum_7:-RHSA-2024:2002}" ;;
        8)  erratum="${PARAM_cv_incremental_erratum_8:-RHSA-2025:1372}" ;;
        9)  erratum="${PARAM_cv_incremental_erratum_9:-RHSA-2025:17742}" ;;
        10) erratum="${PARAM_cv_incremental_erratum_10:-RHSA-2025:20126}" ;;
        *)  continue ;;
        esac

        test="94f-cv-incremental-update-${cv_name}-${erratum}"
        ap "${test}.log" \
          -e "cv='$cv_name'" \
          -e "lifecycle_environments='$cv_lce'" \
          -e "errata_ids='[\"$erratum\"]'" \
          -e "description='Incremental update $rel: $erratum'" \
          playbooks/tests/FAM/cv_incremental_update.yaml
        e IncrementalContentViewUpdate "${logs}/${test}.log"
    done
} # incremental_cv_updates_fam
