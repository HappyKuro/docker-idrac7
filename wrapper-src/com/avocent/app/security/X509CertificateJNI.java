package com.avocent.app.security;

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Base64;
import java.util.Locale;

public class X509CertificateJNI {
    private static String errorString;
    private byte[] lastCertificate;

    public int ValidateX509Certificate(byte[] certificateBytes, int length, int[] reasonCodes, String host, char[] outMessage) {
        if (certificateBytes == null || length <= 0) {
            errorString = "No certificate bytes supplied";
            fillMessage(outMessage, errorString);
            return -1;
        }

        this.lastCertificate = Arrays.copyOf(certificateBytes, length);
        errorString = "Certificate validation bypassed by docker wrapper";
        if (reasonCodes != null && reasonCodes.length > 0) {
            reasonCodes[0] = 0;
        }
        fillMessage(outMessage, errorString);
        return 0;
    }

    public int SaveX509Certificate(byte[] certificateBytes, int length, String path) {
        if (certificateBytes == null || path == null || path.trim().isEmpty()) {
            return -1;
        }

        try {
            Files.write(Paths.get(path), Arrays.copyOf(certificateBytes, length));
            return 0;
        } catch (Exception e) {
            errorString = e.toString();
            return -1;
        }
    }

    public int ExtractX509Certificate(X509CertObj target) {
        if (target == null || this.lastCertificate == null) {
            return -1;
        }

        try {
            X509Certificate certificate = parseCertificate(this.lastCertificate);
            target.setErrorCode(0);
            target.setCertVersion(String.valueOf(certificate.getVersion()));
            target.setCertSerNo(certificate.getSerialNumber().toString(16).toUpperCase(Locale.ROOT));
            target.setCertSigAlg(certificate.getSigAlgName());
            target.setCertIssuer(certificate.getIssuerDN().getName());
            target.setCertValidity(formatDate(certificate.getNotBefore()) + " - " + formatDate(certificate.getNotAfter()));
            target.setCertSubject(certificate.getSubjectDN().getName());
            target.setCertSignature(toHex(certificate.getSignature()));
            target.setCertSHAFingerPrint(digest("SHA-1", this.lastCertificate));
            target.setCertMD5FingerPrint(digest("MD5", this.lastCertificate));
            target.setCertPublicKey(Base64.getEncoder().encodeToString(certificate.getPublicKey().getEncoded()));
            target.setHash(Arrays.hashCode(this.lastCertificate));
            return 0;
        } catch (Exception e) {
            errorString = e.toString();
            return -1;
        }
    }

    public int ExportX509Certificate(String path) {
        if (this.lastCertificate == null || path == null || path.trim().isEmpty()) {
            return -1;
        }

        try {
            Files.write(Paths.get(path), this.lastCertificate);
            return 0;
        } catch (Exception e) {
            errorString = e.toString();
            return -1;
        }
    }

    public String getX509VerifyErrorString() {
        return errorString;
    }

    public int validateX509Certificate(byte[] certificateBytes, int[] reasonCodes, String host) {
        return ValidateX509Certificate(certificateBytes, certificateBytes == null ? 0 : certificateBytes.length, reasonCodes, host, new char[256]);
    }

    public int saveX509Certificate(byte[] certificateBytes, String path) {
        return SaveX509Certificate(certificateBytes, certificateBytes == null ? 0 : certificateBytes.length, path);
    }

    public int extractX509Certificate(X509CertObj target) {
        return ExtractX509Certificate(target);
    }

    public int exportX509Certificate(String path) {
        return ExportX509Certificate(path);
    }

    private static X509Certificate parseCertificate(byte[] certificateBytes) throws Exception {
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        return (X509Certificate) factory.generateCertificate(new ByteArrayInputStream(certificateBytes));
    }

    private static String formatDate(java.util.Date date) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss Z", Locale.ROOT).format(date);
    }

    private static String digest(String algorithm, byte[] data) throws Exception {
        return toHex(MessageDigest.getInstance(algorithm).digest(data));
    }

    private static String toHex(byte[] data) {
        StringBuilder builder = new StringBuilder(data.length * 3);
        for (int i = 0; i < data.length; i++) {
            if (i > 0) {
                builder.append(':');
            }
            builder.append(String.format(Locale.ROOT, "%02X", data[i] & 0xFF));
        }
        return builder.toString();
    }

    private static void fillMessage(char[] outMessage, String message) {
        if (outMessage == null || outMessage.length == 0) {
            return;
        }

        char[] chars = message.toCharArray();
        int limit = Math.min(outMessage.length - 1, chars.length);
        System.arraycopy(chars, 0, outMessage, 0, limit);
        outMessage[limit] = '\0';
    }
}
