use persistence_postgres::{
    CatalogReleaseActivationRequest, CatalogReleaseRollbackRequest, FdcFoundationImportRequest,
    FdcFoundationValidationRequest, activate_catalog_release, connect, import_fdc_foundation_json,
    migrate, stage_catalog_rollback, validate_fdc_foundation_json,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::{env, fs};
use uuid::Uuid;

const SOURCE_RELEASE: &str = "2026-04-30";
const SOURCE_ARCHIVE_SHA256: &str =
    "186e988ec542e913f51ef62b86a47758e8cdd0d1dc3889e7b055581f3c09c77a";
const SOURCE_PAYLOAD_SHA256: &str =
    "27d1fe3fd89edfbe528ed915da5619320e1d004d4594603a1b19bdb1511590cc";
const NORMALIZED_PAYLOAD_SHA256: &str =
    "8af923182f75bce502ba9c14aca2228fd4dad095eb1a8d6a7aba6a2b5101c19d";
const PREPROCESSING_POLICY: &str = "fdc_foundation_2026_04_null_tail_v1";
const APPROVAL_REFERENCE: &str = "github:pull/31#issuecomment-5305073122";
const CREATED_BY: &str = "0198f100-0000-7000-8000-000000000099";
const REVIEWER_ID: &str = "0198f100-0000-7000-8000-000000000098";
const FDC_IDS: [u64; 20] = [
    1_750_339, 1_750_340, 1_750_341, 1_750_342, 1_750_343, 1_999_626, 1_999_627, 1_999_628,
    1_999_629, 1_999_630, 1_999_631, 1_999_632, 1_999_633, 1_999_634, 2_003_586, 2_003_587,
    2_003_588, 2_003_589, 2_003_590, 2_003_591,
];

#[tokio::test]
#[ignore = "staging-only; requires TEST_DATABASE_URL and FDC_STAGING_ARTIFACT_PATH"]
async fn exact_reviewed_fdc_selection_runs_staging_activation_and_rollback_drill() {
    let artifact_path = env::var("FDC_STAGING_ARTIFACT_PATH")
        .expect("FDC_STAGING_ARTIFACT_PATH must point to the extracted April 2026 JSON");
    let source_bytes = fs::read(&artifact_path).expect("the pinned FDC artifact must be readable");
    assert_eq!(sha256_hex(&source_bytes), SOURCE_PAYLOAD_SHA256);

    let validation_request = validation_request();
    let validation_report = validate_fdc_foundation_json(&source_bytes, &validation_request);
    assert_eq!(validation_report.validation_status, "passed");
    assert_eq!(validation_report.selection_status, "validated");
    assert_eq!(validation_report.selected_record_count, FDC_IDS.len());
    assert_eq!(validation_report.selected_energy_missing_count, 0);
    assert_eq!(validation_report.selected_unexpected_legacy_energy_count, 0);
    assert_eq!(
        validation_report.normalized_payload_sha256.as_deref(),
        Some(NORMALIZED_PAYLOAD_SHA256)
    );
    assert_eq!(validation_report.normalized_record_count, Some(363));

    let report_json = validation_report
        .to_pretty_json(&validation_request)
        .expect("validation report must render deterministically");
    let validation_report_hash = sha256_hex(report_json.as_bytes());

    let pool = setup_database().await;
    let import_request = FdcFoundationImportRequest {
        release_version: SOURCE_RELEASE.to_owned(),
        source_published_date: SOURCE_RELEASE.to_owned(),
        object_uri: "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_json_2026-04-30.zip".to_owned(),
        expected_sha256: SOURCE_PAYLOAD_SHA256.to_owned(),
        source_archive_sha256: Some(SOURCE_ARCHIVE_SHA256.to_owned()),
        preprocessing_policy_version: Some(PREPROCESSING_POLICY.to_owned()),
        include_fdc_ids: FDC_IDS.to_vec(),
        created_by: CREATED_BY.to_owned(),
    };
    let imported = import_fdc_foundation_json(&pool, &source_bytes, &import_request)
        .await
        .expect("the exact reviewed FDC selection must stage");
    assert_eq!(imported.selected_record_count, FDC_IDS.len());
    assert_eq!(imported.energy_missing_count, 0);
    assert_eq!(imported.unexpected_legacy_energy_count, 0);
    assert_eq!(imported.source_sha256, SOURCE_PAYLOAD_SHA256);

    assert_staged_selection(&pool, imported.catalog_release_id, FDC_IDS.len()).await;
    let (superseding_bytes, superseding_id) = superseding_payload(&source_bytes);
    let superseding_report_hash = sha256_hex(b"staging-superseding-release");
    let superseding = import_fdc_foundation_json(
        &pool,
        &superseding_bytes,
        &FdcFoundationImportRequest {
            release_version: "2026-04-30-staging-supersede".to_owned(),
            source_published_date: SOURCE_RELEASE.to_owned(),
            object_uri: "staging://fdc/2026-04-30-normalized-supersede.json".to_owned(),
            expected_sha256: sha256_hex(&superseding_bytes),
            source_archive_sha256: None,
            preprocessing_policy_version: None,
            include_fdc_ids: vec![superseding_id],
            created_by: CREATED_BY.to_owned(),
        },
    )
    .await
    .expect("the real-data superseding staging release must stage");
    assert_eq!(superseding.selected_record_count, 1);
    assert_staged_selection(&pool, superseding.catalog_release_id, 1).await;
    prepare_staging_activation_evidence(
        &pool,
        imported.catalog_release_id,
        &validation_report_hash,
    )
    .await;

    let reviewer_id = Uuid::parse_str(REVIEWER_ID).expect("staging reviewer UUID must be valid");
    let activation = activate_catalog_release(
        &pool,
        &CatalogReleaseActivationRequest {
            release_id: imported.catalog_release_id,
            expected_current_active_release: None,
            validation_report_hash: validation_report_hash.clone(),
            reviewer_id,
            approval_reference: APPROVAL_REFERENCE.to_owned(),
        },
    )
    .await
    .expect("validated exact selection must activate in staging");
    assert_eq!(activation.catalog_release_id, imported.catalog_release_id);
    assert_release_status(&pool, imported.catalog_release_id, "active").await;
    assert_source_activation(&pool, imported.dataset_release_id, reviewer_id).await;

    prepare_staging_activation_evidence(
        &pool,
        superseding.catalog_release_id,
        &superseding_report_hash,
    )
    .await;
    activate_catalog_release(
        &pool,
        &CatalogReleaseActivationRequest {
            release_id: superseding.catalog_release_id,
            expected_current_active_release: Some(imported.catalog_release_id),
            validation_report_hash: superseding_report_hash,
            reviewer_id,
            approval_reference: format!("{APPROVAL_REFERENCE}:supersede"),
        },
    )
    .await
    .expect("the real-data superseding release must activate in staging");
    assert_release_status(&pool, imported.catalog_release_id, "superseded").await;
    assert_release_status(&pool, superseding.catalog_release_id, "active").await;

    let rollback = stage_catalog_rollback(
        &pool,
        &CatalogReleaseRollbackRequest {
            source_release_id: imported.catalog_release_id,
            new_version: format!("staging-rollback-{}", Uuid::now_v7()),
            created_by: reviewer_id,
        },
    )
    .await
    .expect("active release must produce an immutable staging rollback snapshot");
    assert_eq!(rollback.source_release_id, imported.catalog_release_id);
    assert_eq!(rollback.validation_report_hash, validation_report_hash);

    let rollback_activation = activate_catalog_release(
        &pool,
        &CatalogReleaseActivationRequest {
            release_id: rollback.rollback_release_id,
            expected_current_active_release: Some(superseding.catalog_release_id),
            validation_report_hash: rollback.validation_report_hash,
            reviewer_id,
            approval_reference: format!("{APPROVAL_REFERENCE}:rollback"),
        },
    )
    .await
    .expect("rollback snapshot must pass the normal activation gate in staging");
    assert_eq!(
        rollback_activation.previous_active_release_id,
        Some(superseding.catalog_release_id)
    );
    assert_release_status(&pool, imported.catalog_release_id, "superseded").await;
    assert_release_status(&pool, superseding.catalog_release_id, "superseded").await;
    assert_release_status(&pool, rollback.rollback_release_id, "active").await;
    assert_source_activation(&pool, imported.dataset_release_id, reviewer_id).await;

    println!(
        "staging drill passed: selected={} dataset_release_id={} catalog_release_id={} rollback_release_id={} report_sha256={}",
        FDC_IDS.len(),
        imported.dataset_release_id,
        imported.catalog_release_id,
        rollback.rollback_release_id,
        validation_report_hash,
    );
}

fn validation_request() -> FdcFoundationValidationRequest {
    FdcFoundationValidationRequest {
        release_version: SOURCE_RELEASE.to_owned(),
        source_published_date: SOURCE_RELEASE.to_owned(),
        object_uri: "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_json_2026-04-30.zip".to_owned(),
        source_payload_filename: Some(
            "FoodData_Central_foundation_food_json_2026-04-30.json".to_owned(),
        ),
        source_archive_sha256: Some(SOURCE_ARCHIVE_SHA256.to_owned()),
        expected_sha256: SOURCE_PAYLOAD_SHA256.to_owned(),
        reviewed_fdc_ids: FDC_IDS.to_vec(),
        preprocessing_policy_version: Some(PREPROCESSING_POLICY.to_owned()),
    }
}

fn superseding_payload(source_bytes: &[u8]) -> (Vec<u8>, u64) {
    let mut root: Value = serde_json::from_slice(source_bytes).expect("source JSON must parse");
    let foods = root["FoundationFoods"]
        .as_array_mut()
        .expect("source must contain FoundationFoods");
    let candidate = foods
        .iter()
        .find(|food| {
            let Some(fdc_id) = food.get("fdcId").and_then(Value::as_u64) else {
                return false;
            };
            if FDC_IDS.contains(&fdc_id) {
                return false;
            }
            let nutrients = food
                .get("foodNutrients")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|nutrient| {
                    let id = nutrient
                        .get("nutrient")
                        .and_then(|value| value.get("id"))
                        .and_then(Value::as_u64)?;
                    let amount = nutrient.get("amount").and_then(Value::as_f64)?;
                    Some((id, amount))
                })
                .collect::<std::collections::BTreeMap<_, _>>();
            [1003, 1004, 1005]
                .iter()
                .all(|id| nutrients.contains_key(id))
                && (nutrients.contains_key(&2048) || nutrients.contains_key(&2047))
        })
        .cloned()
        .expect("source must contain a second real record suitable for staging");
    let superseding_id = candidate
        .get("fdcId")
        .and_then(Value::as_u64)
        .expect("superseding record must have an FDC ID");
    root["FoundationFoods"] = Value::Array(vec![candidate]);
    (
        serde_json::to_vec(&root).expect("superseding staging payload must serialize"),
        superseding_id,
    )
}

async fn setup_database() -> PgPool {
    let database_url = env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL is required");
    let pool = connect(&database_url, 4)
        .await
        .expect("staging database must connect");
    migrate(&pool).await.expect("staging migrations must apply");
    pool
}

async fn assert_staged_selection(pool: &PgPool, release_id: Uuid, expected_count: usize) {
    let counts: (i64, i64, i64) = sqlx::query_as(
        "SELECT
            (SELECT count(*) FROM catalog.catalog_release_profile WHERE catalog_release_id = $1),
            (SELECT count(*) FROM catalog.catalog_release_food_name WHERE catalog_release_id = $1),
            (SELECT count(*) FROM composition.composition_profile profile
              JOIN catalog.catalog_release_profile membership ON membership.profile_id = profile.id
             WHERE membership.catalog_release_id = $1 AND profile.method_metadata->'energy_mapping'->>'status' = 'complete')",
    )
    .bind(release_id)
    .fetch_one(pool)
    .await
    .expect("staged selection counts must be readable");
    let expected = i64::try_from(expected_count).expect("selection count must fit in i64");
    assert_eq!(counts, (expected, expected, expected));
    assert_release_status(pool, release_id, "staged").await;
}

async fn prepare_staging_activation_evidence(
    pool: &PgPool,
    release_id: Uuid,
    validation_report_hash: &str,
) {
    let mut manifest: Value =
        sqlx::query_scalar("SELECT manifest FROM catalog.catalog_release WHERE id = $1")
            .bind(release_id)
            .fetch_one(pool)
            .await
            .expect("staged manifest must be readable");
    manifest["production_eligible"] = Value::Bool(true);
    manifest["validation"] = json!({
        "report_sha256": validation_report_hash,
        "status": "passed",
        "production_eligible": true,
        "staging_only": true,
        "approval_reference": APPROVAL_REFERENCE
    });
    let checksum = sha256_hex(&serde_json::to_vec(&manifest).expect("manifest must serialize"));
    sqlx::query(
        "UPDATE catalog.catalog_release
            SET manifest = $2, checksum_sha256 = $3
          WHERE id = $1 AND status = 'staged'",
    )
    .bind(release_id)
    .bind(&manifest)
    .bind(checksum)
    .execute(pool)
    .await
    .expect("staging validation evidence must be stored");

    sqlx::query(
        "UPDATE composition.composition_profile profile
            SET method_metadata = jsonb_set(profile.method_metadata, '{production_eligible}', 'true'::jsonb)
          WHERE profile.id IN (
              SELECT profile_id FROM catalog.catalog_release_profile WHERE catalog_release_id = $1
          )",
    )
    .bind(release_id)
    .execute(pool)
    .await
    .expect("staging profile evidence must be stored");

    sqlx::query(
        "UPDATE catalog.food_mapping mapping
            SET review_status = 'approved', reviewed_by = $2, reviewed_at = now()
          WHERE mapping.food_id IN (
              SELECT profile.food_id
                FROM catalog.catalog_release_profile membership
                JOIN composition.composition_profile profile ON profile.id = membership.profile_id
               WHERE membership.catalog_release_id = $1
          )",
    )
    .bind(release_id)
    .bind(Uuid::parse_str(REVIEWER_ID).expect("reviewer UUID must be valid"))
    .execute(pool)
    .await
    .expect("staging mapping evidence must be stored");
}

async fn assert_release_status(pool: &PgPool, release_id: Uuid, expected: &str) {
    let status: String =
        sqlx::query_scalar("SELECT status FROM catalog.catalog_release WHERE id = $1")
            .bind(release_id)
            .fetch_one(pool)
            .await
            .expect("catalog release status must be readable");
    assert_eq!(status, expected);
}

async fn assert_source_activation(pool: &PgPool, dataset_release_id: Uuid, reviewer_id: Uuid) {
    let state = sqlx::query(
        "SELECT active_release_id, activated_by
           FROM raw.source_activation
          WHERE active_release_id = $1",
    )
    .bind(dataset_release_id)
    .fetch_one(pool)
    .await
    .expect("source activation pointer must be readable");
    let active_release_id: Uuid = state.try_get("active_release_id").expect("active ID");
    let activated_by: Uuid = state.try_get("activated_by").expect("reviewer ID");
    assert_eq!(active_release_id, dataset_release_id);
    assert_eq!(activated_by, reviewer_id);
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
