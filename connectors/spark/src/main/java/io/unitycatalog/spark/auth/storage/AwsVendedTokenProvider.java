package io.unitycatalog.spark.auth.storage;

import io.unitycatalog.spark.UCHadoopConf;
import org.apache.hadoop.conf.Configuration;
import org.sparkproject.guava.base.Preconditions;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials;

public class AwsVendedTokenProvider extends GenericCredentialProvider
    implements AwsCredentialsProvider {

  /**
   * Constructor for the hadoop's CredentialProviderListFactory#buildAWSProviderList to initialize.
   */
  public AwsVendedTokenProvider(Configuration conf) {
    initialize(conf);
  }

  @Override
  public GenericCredential initGenericCredential(Configuration conf) {
    if (conf.get(UCHadoopConf.S3A_INIT_ACCESS_KEY) != null
        && conf.get(UCHadoopConf.S3A_INIT_SECRET_KEY) != null) {

      String accessKey = conf.get(UCHadoopConf.S3A_INIT_ACCESS_KEY);
      String secretKey = conf.get(UCHadoopConf.S3A_INIT_SECRET_KEY);
      // Session token can be null for MinIO / static credentials
      String sessionToken = conf.get(UCHadoopConf.S3A_INIT_SESSION_TOKEN);

      long expiredTimeMillis =
          conf.getLong(UCHadoopConf.S3A_INIT_CRED_EXPIRED_TIME, Long.MAX_VALUE);
      Preconditions.checkState(
          expiredTimeMillis > 0,
          "Expired time %s must be greater than 0, " + "please check configure key '%s'",
          expiredTimeMillis,
          UCHadoopConf.S3A_INIT_CRED_EXPIRED_TIME);

      return GenericCredential.forAws(accessKey, secretKey, sessionToken, expiredTimeMillis);
    } else {
      return null;
    }
  }

  @Override
  public AwsCredentials resolveCredentials() {
    GenericCredential generic = accessCredentials();

    // Wrap the GenericCredential as an AwsCredentials.
    io.unitycatalog.client.model.AwsCredentials awsTempCred =
        generic.temporaryCredentials().getAwsTempCredentials();
    Preconditions.checkNotNull(
        awsTempCred, "AWS temp credential of generic credentials cannot be null");

    // MinIO / static credentials often have no session token. The UC API may omit session_token
    // (Java client returns null) or send "". AWS SDK v2 AwsSessionCredentials requires non-null
    // sessionToken, so use AwsBasicCredentials when missing or blank. This is why local
    // test-spark-minio-create-insert.sh can work (server may send "") while Kyuubi/FluxEngine
    // can NPE (server or client returns null)—fix lives here in the connector only.
    String sessionToken = awsTempCred.getSessionToken();
    boolean hasSessionToken = sessionToken != null && !sessionToken.isBlank();
    if (hasSessionToken) {
      return AwsSessionCredentials.builder()
          .accessKeyId(awsTempCred.getAccessKeyId())
          .secretAccessKey(awsTempCred.getSecretAccessKey())
          .sessionToken(sessionToken.trim())
          .build();
    }
    return AwsBasicCredentials.create(
        awsTempCred.getAccessKeyId(), awsTempCred.getSecretAccessKey());
  }
}
