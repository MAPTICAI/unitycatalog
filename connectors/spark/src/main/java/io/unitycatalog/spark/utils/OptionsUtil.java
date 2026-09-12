package io.unitycatalog.spark.utils;

public class OptionsUtil {
  private OptionsUtil() {}

  public static final String URI = "uri";
  public static final String TOKEN = "token";
  public static final String WAREHOUSE = "warehouse";

  public static final String RENEW_CREDENTIAL_ENABLED = "renewCredential.enabled";
  public static final boolean DEFAULT_RENEW_CREDENTIAL_ENABLED = true;

  /**
   * S3-compatible endpoint override (e.g. MinIO). When set, used for fs.s3a.endpoint instead of the
   * UC server response. Use in-cluster URL in K8s (e.g. http://minio.namespace.svc:9000).
   */
  public static final String S3_ENDPOINT = "s3.endpoint";

  public static boolean getBoolean(
      Map<String, String> props, String property, boolean defaultValue) {
    String value = props.get(property);
    if (value != null) {
      return Boolean.parseBoolean(value);
    }
    return defaultValue;
  }
}
