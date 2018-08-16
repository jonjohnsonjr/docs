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

  // Shared by all Versions, configuration for the conversion webhook.
  Conversion *CustomResourceConversion

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

[Example of handling a `ConversionRequest`.]( https://github.com/kubernetes/community/blob/master/contributors/design-proposals/api-machinery/customresource-conversion-webhook.md#examples)


## Impl

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

We need users to provide something that maps versions to individual
conversion functions, then we can produce an implementation of the
`Convertible` interface for them, e.g.:

```go
package convert

// TODO: Find better names for this stuff.
type ConversionMapping struct {
  OriginalVersion string
  DesiredVersion  string
  Convert func (runtime.RawExtension) (runtime.RawExtension, error)
}

func MakeConvertFunction(cms []ConversionMapping) func (in runtime.RawExtension, version string) (*runtime.RawExtension, error) {
  // Return a function that walks through `cms`, upgrading/downgrading until we reach desired `version`.
}
```

We can also help validate that they have complete coverage for all the versions
in a CRD Spec.
```go
func Validate(cms []ConversionMapping, spec CustomResourceDefinitionSpec) error {
  // Validate that it's possible to reach any version in spec.Versions from any other version.
  // We don't need to call any `Convert` functions, just that there are edges between
  // every version in `cms`.
}
```

This is probably overkill for CRDs that have only 2 or 3 different versions.
They would probably want to implement the `Convertible` interface directly,
but as the number of possible conversion invocations grows pretty quickly,
for `N` versions, there are `N * N-1` combinations of versions. The above
scheme reduces that to `2N - 2`.

## Testing

### unit

The `Convertible` interface allows us to write simple table tests
for individual conversions, something like:

```go
type TableRow struct {
  Name    string
  Version string
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

## Questions

When is it reasonable to start merging this code? Do we expect users to upgrade to alpha? Beta? GA?
We probably don't want to start this until at least 1.11 is GA.

Some changes might not be roundtrippable. Can we just shove un-roundtrippable stuff into annotations?

Do we want to guarantee that any combination of CRD versions is valid? That seems... hard.
