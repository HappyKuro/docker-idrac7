import java.lang.reflect.Method;
import java.security.Provider;
import java.security.Security;

public final class IdracLauncher {
    private IdracLauncher() {
    }

    public static void main(String[] args) throws Exception {
        ensureSunEcProvider();
        maybePushConfig("IDRAC_FORCE_CIPHER_STRING", "PROPERTY_CIPHER_STRING");
        maybePushConfig("IDRAC_FORCE_PROTOCOL_STRING", "PROPERTY_PROTOCOL_STRING");

        String mainClassName = System.getProperty("idrac.main.class", "com.avocent.idrac.kvm.Main");
        Class<?> mainClass = Class.forName(mainClassName);
        Method mainMethod = mainClass.getMethod("main", String[].class);
        mainMethod.invoke(null, (Object) args);
    }

    private static void ensureSunEcProvider() {
        if (Security.getProvider("SunEC") != null) {
            System.out.println("SunEC provider already available");
            return;
        }

        try {
            Provider provider = (Provider) Class.forName("sun.security.ec.SunEC").newInstance();
            int position = Security.addProvider(provider);
            System.out.println("Registered SunEC provider at position " + position);
        } catch (Exception e) {
            System.out.println("Unable to register SunEC provider");
            e.printStackTrace(System.out);
        }
    }

    private static void maybePushConfig(String envName, String configKey) {
        String value = System.getenv(envName);
        if (value == null || value.trim().isEmpty()) {
            return;
        }

        Thread writer = new Thread(() -> {
            long deadline = System.currentTimeMillis() + 15000L;
            while (System.currentTimeMillis() < deadline) {
                try {
                    Class<?> configClass = Class.forName("com.avocent.e.k");
                    Method putMethod = configClass.getMethod("a", String.class, Object.class);
                    putMethod.invoke(null, configKey, value);
                    Thread.sleep(250L);
                } catch (Throwable t) {
                    // Keep retrying while the app initializes.
                }
            }
        }, "idrac-config-pusher");

        writer.setDaemon(true);
        writer.start();
    }
}
