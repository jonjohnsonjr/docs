# CRD Versioning

## Background

CRDs are currently impossible to upgrade without breaking existing users.
CRD Conversion (expected to land in kubernetes 1.12 alpha) fixes this, but
requires some effort from CRD Authors.

* [CRD Versioning Docs](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definition-versioning)
* [Versioning Proposal](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/api-machinery/customresources-versioning.md)
* [Initial Versioning Implementation](https://github.com/kubernetes/kubernetes/pull/63830)
* [Conversion Proposal](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/api-machinery/customresource-conversion-webhook.md)
* [Conversion tracking issue](https://github.com/kubernetes/features/issues/598)

### Timeline

* Now: [Validation](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definitions/#validation).
	* This is a prereq for Conversion and [Pruning](https://github.com/kubernetes/features/issues/575). We should implement this now.
* 1.11: [Versioning](#versioning) in Alpha.
	* This is not particularly useful until Conversion lands, but that's very far out (Q2 2019).
	* We can use this to implement an [conversion controller](#conversion-controller) to do conversion "manually".
* 1.13: [Conversion](#conversion) in Beta.
	* First-class conversion rolls out; we stop using the conversion controller.

### Versioning

Versioning has landed as alpha in 1.11. This just includes versioning without
conversion. This enables us to:
1. manually migrate versions of CRDs, if we want
2. start implementing our migration code against the new Spec for CRDs.

Relevant changes to `CustomResourceDefinitionSpec`:

```go
type CustomResourceDefinitionSpec struct {
  // ...

  // This now corresponds to the first version in the Versions list.
  Version string

  // Sorted by "kube-like" version style, for example:  v10, v2, v1, v11beta2, v10beta3, v3beta1, v12alpha1, v11alpha2, foo1, foo10
  // TODO: where can we find the "kube-like" sorting implementation?
  // Note: the ordering here is different from what was in the proposal.
  Versions []CustomResourceDefinitionVersion

  // ...
}
```

For each CRD Group, you need to define which Version is stored in etcd.
You can also enable/disable which versions the API is able to serve.
This is represented by a `CustomResourceDefinitionVersion`:


```go
type CustomResourceDefinitionVersion struct {
  // Name of the Version, e.g. "v1", "v1beta1", "v1alpha2"
  Name    string

  // Whether this Version is able to be served via the REST API.
  Served  bool

  // Whether this Version is the Version that is stored in etcd.
  // There must be exactly one storage version per CRD.
  Storage bool
}
```

### Conversion

Conversion is expected to land as alpha in 1.12.

Conversion between versions is done via a webhook.
There is one conversion webhook per CRD `Group`.
It needs to handle conversion between any two versions, responding to a `ConversionRequest`
with a `ConversionResponse`:

```go
type ConversionRequest struct {
  // UID is an identifier for the individual request/response. Useful for logging.
  UID types.UID
  // The version to convert given object to. E.g. "stable.example.com/v1"
  APIVersion string
  // Object is the CRD object to be converted.
  Object runtime.RawExtension
}

type ConversionResponse struct {
  // UID is an identifier for the individual request/response.
  // This should be copied over from the corresponding ConversionRequest.
  UID types.UID
  // ConvertedObject is the converted version of request.Object.
  ConvertedObject runtime.RawExtension
}
```

Relevant changes to `CustomResourceDefinitionSpec`:

```go
type CustomResourceDefinitionSpec struct {
  // ...

  // Shared by all Versions, configuration for the conversion webhook.
  Conversion *CustomResourceConversion

  // ...
}
```

[Example of handling a `ConversionRequest`.](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/api-machinery/customresource-conversion-webhook.md#examples)

#### Dynamic Certificates

In `pkg/webhook`, we [dynamically generate certificates](https://github.com/knative/pkg/blob/eedc0a939db24a877b93b6e90c95ebb8591911bb/webhook/webhook.go#L272).
This precludes us defining our CRDs as static yaml (as we currently do), since
we won't know the Conversion webhook configuration until after our
`pkg/webhook` process comes online.

To fix that, we'll need to have the webhook register our CRDs for us.

TODO: What is the best way to do that?

Options:
* Just inline the spec directly into `cmd/webhook/main.go` (or under `pkg/apis`)?
* Move the yamls under `cmd/webhook` and jsonpatch the webhook config?


## Impl

We'll separate this implementation into two pieces:

1. A `Convertible` interface for `pkg/webhook` that maps directly to the k8s
   conversion webhook implementation. This allows flexibility for the consumers
	 of `pkg/webhook` to implement their conversion in any way.
2. A `SimpleConverter` interface for a new package, `pkg/convert`, that makes
   the implementation easier. This is a bit more opinionated, and assumes
	 that users will always want to do "one hop" upgrade/downgrades.
	 This package makes satisfying the above `Convertible` interface simpler,
	 but its use is optional.

### knative/pkg/webhook

Assuming we can reuse our existing webhook for `CustomResourceConversion`,
we can extend knative/pkg/webhook to support conversion.

We can make `knative/pkg/webhook` handle the [request/response boilerplate](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/api-machinery/customresource-conversion-webhook.md#webhook-requestresponse)
and require each GenericCRD to just implement a simple `Convert` method:

`knative/pkg/apis/convert.go`:

```go
// Convertible defines an interface for converting an object to a different version.
type Convertible interface {
	Convert(in runtime.RawExtension, version string) (*runtime.RawExtension, error)
}
```

`knative/pkg/webhook/webhook.go`:
```go
type GenericCRD interface {
  apis.Defaultable
  apis.Validatable
  apis.Convertible // *New*

  // ...
}
```

### knative/pkg/convert

The `Convertible` interface is flexible enough that a CRD can use whatever
strategy it wants. Unfortunately, that's probably too flexible (CRD authors
would need to implement a conversion function from any version to any other
version) -- we can be a bit prescriptive here to make implementing
`Convert` easier.

A straightforward strategy to allow converting between arbitrary versions
is to allow converting +/- one version and repeatedly converting the CRD
until it is the desired version. This is possible because CRD versions
are [ordered](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definition-versioning/#version-priority).
Library users essentially just have to implement a doubly linked list of
conversion functions between adjacent versions.

We define a `SimpleConverter` interface that allows upgrading from an older
package and downgrading to an older package. By structuring it this way (new
packages depend only on the adjacent, older package), we avoid dependency
cycles.

```go
type SimpleConverter interface {
	UpgradeFrom(old runtime.RawExtension) (*runtime.RawExtension, error)
	Downgrade() (*runtime.RawExtension, error)
}
```

E.g. a newer `v1alpha2` package is responsible for both upgrading from and
downgrading to the older `v1alpha1` package.

```
func downgradeFromAlpha2ToAlpha1() {
  v1alpha1Foo, err := v1alpha2.Downgrade()
  // ...
}

func upgradeFromAlpha1ToAlpha2() {
  v1alpha2Foo, err := v1alpha2.UpgradeFrom(v1alpha1Foo)
  // ...
}
```

We can potentially use some reflection/codegen to make this nicer, i.e. more
typesafe. Ideally, v1alpha2's implementation would look like this instead:

```go
func UpgradeFrom(old *v1alpha1.Foo) (*Foo, error) {
	// Do some upgrading.
}

func (f *Foo) Downgrade() (*v1alpha1.Foo, error)
	// Do some downgrading.
}
```

### Conversion Controller

(May be a Conversion Job instead.)

CRD [Conversion](#conversion) is pretty far out (Q2 2019).
The docs describe a [manual upgrade process](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definition-versioning/#upgrade-existing-objects-to-a-new-stored-version) to use in the meantime:

1. Set `v1` as the storage in the CustomResourceDefinition file and apply it using kubectl. The `storedVersions` is now `v1beta1`, `v1`.
1. Write an upgrade procedure to list all existing objects and write them with the same content. This forces the backend to write objects in the current storage version, which is `v1`.
1. Update the CustomResourceDefinition `Status` by removing `v1beta1` from `storedVersions` field.

Since we'd like to upgrade CRDs before that, we need an alternative
implementation. We can implement a controller to do the above process, but
less manually.

In a perfect world, we'd just need something like this:

```yaml
apiVersion: pkg.knative.dev/v1alpha1
kind: Conversion
metadata:
  name: upgrade-services
  namespace: default
spec:
  group: serving.knative.dev
  oldVersion: v1alpha1
  newVersion: v1alpha2
  kind: CustomResourceDefinition
  # More restrictions? Upgrade individual instances of a CRD? Selectors?
```

TODO: Define the `Conversion` CRD spec.

TODO: What kind of access do we need to be allowed to perform this?

We'll need some way to invoke the `Convert` method of `GenericCRD`.
We can do the same thing that we do in `pkg/webhook` library , i.e.:

* Create a `ConversionController` analogous to the [`AdmissionController`](https://github.com/knative/pkg/blob/eedc0a939db24a877b93b6e90c95ebb8591911bb/webhook/webhook.go#L109).
* Accept a list of [Handlers](https://github.com/knative/pkg/blob/eedc0a939db24a877b93b6e90c95ebb8591911bb/webhook/webhook.go#L112) that implement the `Convertible` interface.
* Use `pkg/controller` to implement a CRD that reconciles old versions to the new version by calling `Convert`.

Once the conversion webhook stuff lands, we can just rip this out or move it
into `pkg/webhook`.

Questions:

* If the CRD to be upgraded isn't registered or doesn't implement `Convertible`, we could still do a simple NOP upgrade that just reads the old version and writes it as the new version. Is that worth doing? (I think probably not.)
* Does it make more sense for this to just be a Job? It's more or less a one-off thing. Being an ongoing process makes it more similar to the actual conversion webhook, though...


## Testing

### unit

The `Convertible` interface allows us to write simple table tests
for individual conversions, something like:

```go
type TableRow struct {
  Name    string
  Input   runtime.RawExtension
  Output  runtime.RawExtension
  Error   error
}
```

This should be sufficient to test that a CRD's `Convert` function works as
expected.

### e2e

Ideally, all the e2e tests would work for every version, so we could just run
all the tests against every version of the CRD, upgrading between test runs.

In practice, this seems wasteful (we'd want coverage for the cross-product of
all CRD versions) and unlikely to succeed (we can't write e2e tests that rely
on newer CRD versions).

Instead, I propose we make the current style of e2e/conformance tests apply only
to the latest version (at HEAD), and define a set of e2e tests that exclusively
exercise the upgrade/downgrade of CRDs. It might make sense to define a min/max
version for which one of these tests is valid, but for now let's assume a simple
test that should be valid for any CRD version.

TODO: We can probably just use go build tags to differentiate these tests.

Since the complete list of versions is specified in the CRD Spec
(`Versions []CustomResourceDefinitionVersion`), we can use that to drive these
tests. Some pseudo-code:

```go
type CRDVersionTest struct {
  Name  string

  Spec CustomResourceDefinitionSpec
  MinVersion string
  MaxVersion string

  // The starting CRD
  Seed runtime.RawExtension

  // Probably not the right thing, just some test func.
  Test testing.InternalTest
}

func RunCRDVersionTest(t, *testing.T, cvt CRDVersionTest) {
	// Create the starting resource.
	crd := createSeed(t, cvt.Seed)

	// Run the test with the starting resource.
	cvt.Test(t)

	// This is casually described in the docs, but we need to find an impl.
	versions := kubesort(cvt.Spec.Versions)

	// Upgrade from MinVersion through MaxVersion, running the Test after each upgrade.
	for i, v := range(versions) {
		if cvt.MinVersion <= v  && v < cvt.MaxVersion {
			// Either calls Convert or induces k8s to upgrade it.
			crd = ConvertCRD(t, crd, v)
			cvt.Test(t)
		}
	}

	// Downgrade from MaxVersion through MinVersion, running the Test after each downgrade.
	for i, v := range(cvt.Spec.Versions) {
		if cvt.MinVersion < v  && v <= cvt.MaxVersion {
			// Either calls Convert or induces k8s to downgrade it.
			crd = ConvertCRD(t, crd, v)
			cvt.Test(t)
		}
	}
}
```

TODO: Sequence diagrams.

## Support

[TODO](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)

## Questions

When is it reasonable to start merging this code? Do we expect users to upgrade to alpha? Beta? GA?
We probably don't want to start this until at least 1.11 is GA.

Some changes might not be roundtrippable. Can we just shove un-roundtrippable stuff into annotations?

Do we want to guarantee that any combination of CRD versions is valid? That seems... hard.
